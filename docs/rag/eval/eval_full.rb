# frozen_string_literal: true

# Éval FULL (génération) — tourne DANS le conteneur (`rails runner`).
# Entrée : JSON [{id, question}] (ARGV[0]). Sortie : JSONL sur stdout.
#
# Pour chaque question, émet les deux versions de l'evidence :
#   - prod_block / prod_sources : instructions_block + for_question du
#     plugin de prod (retrieval hybrid grain topic, tel qu'envoyé au LLM)
#   - posts : top-25 grain post natif (pour construire côté hôte le bloc
#     « nouveau pipeline » : rerank → dédup topic → top-6)
#
# La première ligne émise est {"type":"persona","system_prompt":...}.

require "json"

questions = JSON.parse(File.read(ARGV[0]))

persona = AiAgent.find_by(name: "Guide Depiedencap")
puts JSON.generate({ type: "persona", system_prompt: persona&.system_prompt })
$stdout.flush

questions.each do |q|
  out = { id: q["id"], question: q["question"] }
  %w[category expected_behavior expected_topic_ids
     inject_evidence inject_title].each do |k|
    out[k] = q[k] if q.key?(k)
  end

  # --- pipeline prod (grain topic, tel quel) ---------------------------------
  begin
    out["prod_block"] =
      DepiedencapAiCitations::Retrieval.instructions_block(q["question"])
    out["prod_sources"] =
      DepiedencapAiCitations::Retrieval.for_question(q["question"]).map do |s|
        { title: s[:title], url: s[:url], via: s[:via] }
      end
  rescue StandardError => e
    out["prod_error"] = "#{e.class}: #{e.message}"
  end

  # --- candidats grain post (nouveau pipeline : rerank côté hôte) ------------
  out["posts"] =
    begin
      qvec = DiscourseAi::Embeddings::Vector.instance.vector_from(q["question"])
      sql = <<~SQL
        SELECT e.post_id, p.topic_id, p.post_number, t.title, t.slug,
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
          slug: row["slug"],
          title: row["title"],
          dist: row["dist"].to_f.round(4),
          text: "#{row["title"]}. #{raw}",
        }
      end
    rescue StandardError => e
      [{ error: "#{e.class}: #{e.message}" }]
    end

  puts JSON.generate(out)
  $stdout.flush
end
