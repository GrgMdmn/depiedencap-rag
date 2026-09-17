# frozen_string_literal: true

# Backfill des embeddings « enrichis » (config C) — tourne DANS le conteneur
# Discourse (`rails runner`). Écrit dans ai_posts_embeddings avec
# strategy_id = 2, en cohabitation avec le backfill natif (strategy_id = 1).
#
# Texte embeddé = titre + catégorie + tags (comme Truncation natif)
#   + extrait du message initial du fil (si le post n'est pas l'OP)
#   + extrait du post auquel il répond (reply_to_post_number)
#   + contenu du post — tronqué à max_sequence_length - 2.
#
# Hypothèse testée : le contexte parent/OP lève l'ambiguïté des réponses
# courtes (« oui pareil en 8.5 ») que le grain post nu ne contextualise pas.
#
# Relançable : ne traite que les posts sans ligne strategy_id=2.
# Usage : docker cp backfill_enriched.rb app:/tmp/ && docker exec -d app bash -lc \
#   'cd /var/www/discourse && su discourse -c "bundle exec rails runner \
#    /tmp/backfill_enriched.rb >> /tmp/enriched.log 2>&1"'

require "openssl"
require "json"

STRATEGY_ID = 2
STRATEGY_VERSION = 1
LIMIT = Integer(ENV["BACKFILL_LIMIT"] || 500_000)
BATCH = 1_000
MAX_THREADS = 40
OP_EXCERPT_CHARS = 500
PARENT_EXCERPT_CHARS = 400

vdef = EmbeddingDefinition.find(1)
vector = DiscourseAi::Embeddings::Vector.new(vdef)
max_length = vdef.max_sequence_length - 2
tokenizer = vdef.tokenizer
EMBED_PROMPT = vdef.embed_prompt.presence

def plain(cooked)
  Nokogiri::HTML5.fragment(cooked.to_s).text.gsub(/\s+/, " ").strip
end

def topic_information(topic)
  info = +"#{topic&.title}\n\n"
  info << "#{topic.category.name}\n\n" if topic&.category&.name.present?
  info << "#{topic.tags.pluck(:name).join(', ')}\n\n" if SiteSetting.tagging_enabled && topic&.tags.present?
  info
end

def prepare_enriched(post, ops, parents, tokenizer, max_length)
  text = +topic_information(post.topic)
  unless post.is_first_post?
    op = plain(ops[post.topic_id])[0, OP_EXCERPT_CHARS]
    text << "Message initial : #{op}\n\n" if op.present?
  end
  if post.reply_to_post_number
    parent = plain(parents[[post.topic_id, post.reply_to_post_number]])[0, PARENT_EXCERPT_CHARS]
    text << "En réponse à : #{parent}\n\n" if parent.present?
  end
  text << plain(post.cooked)

  prepared = tokenizer.truncate(
    text, max_length, strict: SiteSetting.ai_strict_token_counting
  )
  [EMBED_PROMPT, prepared].compact.join(" ")
end

scope = Post.where(deleted_at: nil, post_type: Post.types[:regular])
scope = scope.public_posts unless SiteSetting.ai_embeddings_generate_for_pms
ids = scope.where(<<~SQL).order(:id).limit(LIMIT).pluck(:id)
    NOT EXISTS (
      SELECT 1 FROM ai_posts_embeddings e
      WHERE e.post_id = posts.id AND e.model_id = #{vdef.id}
        AND e.strategy_id = #{STRATEGY_ID}
    )
  SQL

puts "#{Time.now.utc.iso8601} #{ids.size} posts à embedder (strategy_id=#{STRATEGY_ID})"
done = 0

ids.each_slice(BATCH) do |batch|
  posts = Post.includes(topic: %i[category tags]).where(id: batch).index_by(&:id)
  topic_ids = posts.each_value.map(&:topic_id).uniq

  ops = Post.where(topic_id: topic_ids, post_number: 1)
        .pluck(:topic_id, :cooked).to_h

  reply_nums = posts.each_value.filter_map(&:reply_to_post_number).uniq
  parents =
    if reply_nums.empty?
      {}
    else
      Post.where(topic_id: topic_ids, post_number: reply_nums)
        .pluck(:topic_id, :post_number, :cooked)
        .each_with_object({}) { |row, h| h[[row[0], row[1]]] = row[2] }
    end

  pool = Scheduler::ThreadPool.new(min_threads: 0, max_threads: MAX_THREADS, idle_time: 30)
  results = Queue.new
  queued = 0

  batch.each do |pid|
    post = posts[pid]
    next unless post
    prepared = prepare_enriched(post, ops, parents, tokenizer, max_length)
    next if prepared.blank?
    digest = OpenSSL::Digest::SHA1.hexdigest(prepared)
    pool.post do
      results << {
        post_id: pid, digest: digest,
        embeddings: vector.send(:request_embedding!, prepared),
      }
    rescue StandardError => e
      results << e
    end
    queued += 1
  end

  errors = 0
  while queued.positive?
    r = results.pop
    if r.is_a?(StandardError)
      errors += 1
      puts "#{Time.now.utc.iso8601} ERREUR embed: #{r.class}: #{r.message}" if errors <= 3
    else
      DB.exec(<<~SQL, r.merge(model_id: vdef.id, model_version: vdef.version, now: Time.zone.now))
        INSERT INTO ai_posts_embeddings
          (post_id, model_id, model_version, strategy_id, strategy_version,
           digest, embeddings, created_at, updated_at)
        VALUES (:post_id, :model_id, :model_version, #{STRATEGY_ID},
                #{STRATEGY_VERSION}, :digest, '[:embeddings]', :now, :now)
        ON CONFLICT (model_id, strategy_id, post_id) DO UPDATE SET
          model_version = :model_version, strategy_version = #{STRATEGY_VERSION},
          digest = :digest, embeddings = '[:embeddings]', updated_at = :now
      SQL
      done += 1
    end
    queued -= 1
  end
  pool.shutdown
  pool.wait_for_termination(timeout: 30)

  puts "#{Time.now.utc.iso8601} #{done}/#{ids.size} (#{errors} erreurs batch)"
  $stdout.flush
end

puts "#{Time.now.utc.iso8601} terminé : #{done}/#{ids.size}"
