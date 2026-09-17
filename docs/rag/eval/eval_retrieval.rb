# frozen_string_literal: true

# Éval retrieval — tourne DANS le conteneur Discourse (`rails runner`).
# Entrée : fichier JSON [{id, question}] (ARGV[0]). Sortie : JSONL sur stdout.
#
# Rejoue le chemin de production `DepiedencapAiCitations::Retrieval` SANS son
# cache (`retrieve` direct) et décompose par canal pour l'attribution :
#   - semantic : SemanticSearch seul (le chemin embeddings actuel, grain topic)
#   - keyword  : Search.execute sur les requêtes dérivées (queries_for)
#   - hybrid   : retrieve() complet (fusion + gate titre + boosts)
#
# Chaque entrée : {id, semantic: [{topic_id, post_id}], keyword: [...],
#                  posts: [{post_id, topic_id, post_number, dist}],
#                  hybrid: [{topic_id, title, via}]}
#
# Canal `posts` : cosine direct sur ai_posts_embeddings (grain post natif,
# texte embeddé = titre+cat+tags+post — stratégie Truncation). Topic dedup :
# première occurrence = rang du topic (design « agrégation par topic »).
#
# Usage (depuis l'hôte) : docker cp questions.json app:/tmp/ && docker exec app
#   su discourse -c "bundle exec rails runner /tmp/eval_retrieval.rb /tmp/q.json"

require "json"

questions = JSON.parse(File.read(ARGV[0]))
guardian = Guardian.new

questions.each do |q|
  out = { id: q["id"], question: q["question"] }

  # --- canal sémantique seul -------------------------------------------------
  out["semantic"] =
    begin
      DepiedencapAiCitations::Retrieval
        .semantic_posts(q["question"])
        .map { |p| { topic_id: p.topic_id, post_id: p.id } }
        .uniq { |h| h[:topic_id] }
    rescue StandardError => e
      [{ error: "#{e.class}: #{e.message}" }]
    end

  # --- canal keyword seul ----------------------------------------------------
  out["keyword"] =
    begin
      seen = {}
      DepiedencapAiCitations::Retrieval.queries_for(q["question"]).each do |query|
        results = Search.execute(query, guardian: guardian, type_filter: "topic")
        Array(results&.posts).first(25).each do |post|
          seen[post.topic_id] ||= { topic_id: post.topic_id, post_id: post.id }
        end
      end
      seen.values
    rescue StandardError => e
      [{ error: "#{e.class}: #{e.message}" }]
    end

  # --- canal grain post (pgvector direct, si backfill présent) ---------------
  out["posts"] =
    begin
      if ActiveRecord::Base.connection.execute(
        "SELECT count(*) FROM ai_posts_embeddings",
      ).first["count"].to_i.zero?
        []
      else
        qvec = DiscourseAi::Embeddings::Vector.instance.vector_from(q["question"])
        raise "embedding vide" if qvec.blank?
        sql = <<~SQL
          SELECT e.post_id, p.topic_id, p.post_number, t.title,
                 e.embeddings <=> '#{qvec}' AS dist
          FROM ai_posts_embeddings e
          JOIN posts p ON p.id = e.post_id
          JOIN topics t ON t.id = p.topic_id
          WHERE e.model_id = 1 AND e.strategy_id = 1
            AND p.deleted_at IS NULL
          ORDER BY e.embeddings <=> '#{qvec}'
          LIMIT 25
        SQL
        rows = ActiveRecord::Base.connection.execute(sql).to_a
        post_ids = rows.map { |r| r["post_id"].to_i }
        raws = Post.where(id: post_ids).pluck(:id, :raw).to_h
        rows.map do |row|
          raw = raws[row["post_id"].to_i].to_s.gsub(/\s+/, " ").strip[0, 300]
          {
            post_id: row["post_id"].to_i,
            topic_id: row["topic_id"].to_i,
            post_number: row["post_number"].to_i,
            dist: row["dist"].to_f.round(4),
            text: "#{row["title"]}. #{raw}",
          }
        end
      end
    rescue StandardError => e
      [{ error: "#{e.class}: #{e.message}" }]
    end

  # --- canal grain post enrichi (strategy_id=2 : + extrait OP + parent) -----
  out["posts_enr"] =
    begin
      if ActiveRecord::Base.connection.execute(
        "SELECT count(*) FROM ai_posts_embeddings WHERE strategy_id = 2",
      ).first["count"].to_i.zero?
        []
      else
        qvec ||= DiscourseAi::Embeddings::Vector.instance.vector_from(q["question"])
        sql = <<~SQL
          SELECT e.post_id, p.topic_id, p.post_number, t.title,
                 e.embeddings <=> '#{qvec}' AS dist
          FROM ai_posts_embeddings e
          JOIN posts p ON p.id = e.post_id
          JOIN topics t ON t.id = p.topic_id
          WHERE e.model_id = 1 AND e.strategy_id = 2
            AND p.deleted_at IS NULL
          ORDER BY e.embeddings <=> '#{qvec}'
          LIMIT 25
        SQL
        rows = ActiveRecord::Base.connection.execute(sql).to_a
        post_ids = rows.map { |r| r["post_id"].to_i }
        raws = Post.where(id: post_ids).pluck(:id, :raw).to_h
        rows.map do |row|
          raw = raws[row["post_id"].to_i].to_s.gsub(/\s+/, " ").strip[0, 300]
          {
            post_id: row["post_id"].to_i,
            topic_id: row["topic_id"].to_i,
            post_number: row["post_number"].to_i,
            dist: row["dist"].to_f.round(4),
            text: "#{row["title"]}. #{raw}",
          }
        end
      end
    rescue StandardError => e
      [{ error: "#{e.class}: #{e.message}" }]
    end

  # --- pipeline hybride complet (ordre = rang final) -------------------------
  out["hybrid"] =
    begin
      DepiedencapAiCitations::Retrieval.retrieve(q["question"]).map do |s|
        { topic_id: s[:url].to_s.split("/").last.to_i, title: s[:title], via: s[:via] }
      end
    rescue StandardError => e
      [{ error: "#{e.class}: #{e.message}" }]
    end

  puts JSON.generate(out)
  $stdout.flush
end
