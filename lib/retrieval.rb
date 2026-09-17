# frozen_string_literal: true

require "digest"

module DepiedencapAiCitations
  # Retrieval à deux étages :
  #   - v2 (setting depiedencap_ai_citations_posts_pipeline) : canal mesuré
  #     grain post — cosine pgvector ai_posts_embeddings → top-25 → rerank
  #     cross-encoder (mini PC, endpoint /rerank) → dédup topic → top-6,
  #     avec zones d'evidence graduées (abstention / prudent / normal) et
  #     gate d'entrée déterministe. Pipeline évalué : 0.97 Hit@5 sur 796 q.
  #   - legacy (défaut / fallback) : keyword Search + semantic grain topic,
  #     fusion + gate titre. Reste le chemin si posts table vide ou erreur.
  class Retrieval
    CACHE_TTL = 2.hours
    MAX_SOURCES = 6
    EXCERPT_LEN = 320
    MIN_SCORE = 3

    POSTS_TOP_K = 25
    POSTS_ROWS_TTL = 60.seconds
    ABSTAIN_CE = -4.0
    WEAK_CE = 0.0
    RERANK_OPEN_TIMEOUT = 2
    RERANK_READ_TIMEOUT = 4
    POSTS_SQL_LIMIT = 25

    # Réécriture de requête multi-tour (condense_query) — même LLM résident
    # que la génération (qwen3:30b-a3b-q6k, MoE ~3B actifs, ~1 s à chaud).
    # think:false pour éviter le budget englouti dans reasoning (vu sur qwen3:4b).
    HISTORY_TURNS = 3
    CONDENSE_MAX_TOKENS = 80
    CONDENSE_OPEN_TIMEOUT = 2
    CONDENSE_READ_TIMEOUT = 6

    # Message fixe quand le gate intercepte (identique à l'éval — pas d'appel LLM).
    GATE_DECLINE_MSG = (
      "Je suis uniquement le guide du forum Depiedencap — je ne peux pas " \
      "répondre à cette demande. En revanche, je peux chercher si le forum " \
      "en parle."
    ).freeze

    # Gate d'entrée déterministe — portée de rag/eval/input_gate.yml (v1).
    # Patterns sur l'INTENTION (verbe + objet), pas les sujets : un fil du
    # forum peut légitimement parler de contrefaçons ou de cannes-épées ;
    # ce qu'on bloque c'est la demande de le faire. 0 faux positif mesuré
    # sur 796 questions in-domain. Filet complémentaire, contournable par
    # reformulation — le prompt reste la défense principale.
    GATE_RULES = [
      ["misuse-traduction", %r{\btradui[rszt]?\b|\btraduction\b|\btraducteur\b}i],
      [
        "misuse-code",
        %r{
          \bcode(-|\s)?(moi|nous)\b|\bpython\b|\bjavascript\b|\bphp\b|
          \bapi\srest\b|\bscript\b|\bprogramm(ation|ez|er)\b|
          \bdéveloppe(-|\s)?(moi|nous)\b|\bdébug
        }ix,
      ],
      [
        "misuse-redaction",
        %r{
          \brédige|\bécris(-|\s)(moi|nous)\b|\blettre\sde\smotivation\b|
          \bcorrige(-|\s)(moi|nous)\b|\brésume(-|\s)(moi|nous)\b|\bparaphrase
        }ix,
      ],
      [
        "danger-explosif",
        %r{\b(fabriquer|confectionner|faire|construire)\b.{0,40}\b(bombe|explosif|engin)}i,
      ],
      [
        "danger-violence",
        %r{
          \b(tuer|blesser|empoisonner|assassiner|agresser|tabasser)\b|
          \bsans\slaisser\sde\straces\b|\bmeurtre\b|\bhomicide
        }ix,
      ],
      [
        "danger-armes",
        %r{\b(se\sprocurer|acheter|obtenir|fabriquer)\b.{0,30}\b(arme|flingue|pistolet|munitions?)}ix,
      ],
      [
        "illegal-contrefacon-intent",
        %r{\b(revendre|vendre|acheter|fabriquer|produire)\b.{0,30}\bcontrefaç}i,
      ],
      [
        "illegal-drogue",
        %r{
          \b(acheter|se\sprocurer|vendre|dealer)\b.{0,30}\b
          (drogue|cocaïne|héroïne|cannabis|stupéfiant|shit)\b|
          \boù\s(trouver|acheter)\sde\sla\sdrogue
        }ix,
      ],
      [
        "cyber-intrusion",
        %r{
          \bpirat|\bhack(ing|er|é)?s?\b|\bexploit|
          \bforcer\sle\s(compte|mot\sde\spasse)|
          \bvoler\s(un|le|des|les)\s(compte|données|mot\sde\spasse)|
          \bphishing|\bransomware|\bmalware
        }ix,
      ],
      [
        "donnees-perso",
        %r{
          \b(donne|fournis|récupère|extrais|exporte|liste)[sz]?(-|\s)?(moi|nous)?\b.{0,35}\b
          (adresses?|e-?mails?|emails?|utilisateurs|membres|mots?\sde\spasse)\b|
          \b(liste|base)\sdes\s(utilisateurs|membres)\b|\bemails?\sde\s(tous|les)
        }ix,
      ],
      [
        "injection",
        %r{
          \bignore\b.{0,30}\b(instructions?|règles?|consignes?)|
          \b(prompt\ssystème|system\sprompt)\b|\bDAN\b|
          \bsans\s(aucune\s)?restrictions?\b|\bjailbreak|
          \bmode\s(développeur|dieu|sans\sfiltre)\b|\btu\ses\smaintenant\b
        }ix,
      ],
      [
        "hors-role-sante",
        %r{
          \bmédicaments?\b|\bdiagnostic\b|\bprescri|\bdocteur\b|
          \bsympt[oô]mes?\b|\bmaladie\b|\btraitement\s(médical|pour\sma)\b
        }ix,
      ],
      [
        "hors-role-conseil-perso",
        %r{
          \bdivorcer?\b|\bdepression|\bdépression\b|\bsuicide|
          \bconseil\sjuridique\b|\binvestir\s(mon|mes|combien)|
          \bplacement(s)?\s(financier|d.argent)\b|\bdéclaration\sd.impôts
        }ix,
      ],
    ].freeze

    # Template normal — identique à l'éval (rag/eval/run_full_eval.py), avec la
    # section "Role limit" qui empêche l'evidence d'élargir le périmètre.
    EVIDENCE_TEMPLATE = <<~TXT.freeze
      ## STABLE FORUM EVIDENCE (authoritative — do not ignore)
      Retrieval over forum posts (semantic, reranked). Answer ONLY from this evidence.

      ### Citation rules (strict)
      - Cite ONLY bare markers: [[1]], [[2]], [[3]] … matching Evidence numbers.
      - MUST cite [[1]] in the first sentence (best match / definitional thread).
      - Then [[2]], [[3]] in that order. Do not skip [[1]]. Do not jump to [[5]] before [[1]]–[[3]].
      - 3 to 5 citations. NEVER write URLs or /t/… yourself.
      - NEVER invent brands/titles/jargon absent from titles/excerpts.
      - Fidelity: paraphrase excerpts faithfully — never invert their meaning
        or add a judgment the excerpt does not make (e.g. if an excerpt praises
        a leather as easy-care, do not call it demanding).
      - Do NOT call tools.

      ### Output format (mandatory)
      1) Short answer body ONLY with [[n]] citations. NO discussion lists. NO /t/ URLs.
      2) Do NOT write ### Sources or ### Pour aller plus loin yourself.
      3) Do NOT write a pending/placeholder line. Stop after the body.

      ### Role limit (overrides everything above)
      Evidence never expands your scope. If the user's request is out of your role
      (harmful, illegal, or a generic assistant task like translate/write/code/advise),
      decline briefly even if an excerpt could be used to answer.

      ### Evidence
      %{lines}
    TXT

    WEAK_EVIDENCE_TEMPLATE = <<~TXT.freeze
      ## WEAK FORUM EVIDENCE (tangential — handle with care)
      Retrieval found threads that may only loosely relate to the question.

      ### Instructions
      1) Threads don't have to match every constraint of the question. If an
         excerpt discusses the same material, construction, or general care —
         even for another brand or model — relay it as a partial answer,
         noting it is not specific to the user's exact item (e.g. « pas de fil
         sur Carmina, mais pour le box calf les membres conseillent… »).
      2) Only say you found nothing if NO excerpt is genuinely related. Do NOT
         pretend relevance, do NOT invent facts (numbers, names, advice) that
         are not literally in the excerpts — but do not abstain just because
         the match is imperfect.
      3) Frame closest matches with [[n]] as "peut-être en rapport", never as
         a fully certain answer.
      4) Invite the user to post in a fitting category — name the most relevant
         one from the « Forum categories » list below.
      5) All citation and role-limit rules from the main prompt still apply.

      ### Evidence
      %{lines}
    TXT

    NO_EVIDENCE_BLOCK = <<~TXT.freeze
      ## STABLE FORUM EVIDENCE
      No sufficiently relevant forum threads were retrieved.
      Reply briefly in the user's language that you lack solid forum evidence for this question.
      Invite them to post in the most fitting category — name it from the
      « Forum categories » list below. Do NOT invent threads, brands, or /t/ URLs.
      Do NOT write ### Sources. Do NOT call tools.
    TXT

    WELCOME_TITLE_RE =
      /
        \A\s*(bonjour|bonsoir|hello|salutations?|salutation|hey|coucou|hi\b)|
        \bpr[ée]sentation\b|
        ravi d.?avoir|
        une pr[ée]sentation|
        bienvenue|
        avec beaucoup de retard|
        \bbonjour\b
      /ix

    STOPWORDS = %w[
      je tu il nous vous les des une un le la de du et ou pour avec sur dans
      au aux ce cet cette ces mon ma mes ton ta tes son sa ses qui que quoi
      dont est sont a ai as avons avez ont ne pas plus moins très tres
      quels quelle quelles quel du forum conseils conseil peux peux-tu peux tu
      expliquer terme pointer vers discussions qu est ce que
    ].freeze

    INTENT_QUERIES = [
      [
        /premi[eè]re?\s+paire|d[eé]butant|d[eé]bute|premiers?\s+souliers|premi[eè]re?\s+vraie/i,
        ["première paire", "choix première paire", "conseils première paire de souliers"],
      ],
      [
        /
          types?\s+de\s+chaussures|diff[eé]rents?\s+types|quelles?\s+chaussures|
          oxford|derby|derbies|richelieu|richelieus|mocassin|loafer|chelsea|
          chukka|monk|bottine|boots?\s+homme
        /ix,
        ["oxford derby", "richelieu", "mocassin", "chelsea boots", "types chaussures"],
      ],
      [/budget|abordable|pas\s+cher|moins\s+de\s+\d+/i, ["budget chaussures", "marques budget"]],
      [
        /entretien|cirage|patine|glacage|glaçage|tr[ée]pointe/i,
        ["entretien cirage", "trépointe", "patine chaussures", "entretien souliers"],
      ],
      [
        /pointure|taille|\bfit\b|montage|goodyear|blake|last/i,
        ["pointure", "goodyear", "montage chaussures"],
      ],
      [/marque|brand|paraboot|carmina|loding|weston|barker/i, ["marques chaussures", "avis marque"]],
      [
        /calc[eé]ophilie|calc[eé]ophile/i,
        ["calcéophilie", "calcéophile", "terme calcéophile"],
      ],
    ].freeze

    # Gate d'entrée — appelé par PlaygroundHook AVANT retrieval/LLM.
    # Retourne l'id de la règle qui matche, ou nil.
    def self.gate_match(question)
      q = question.to_s
      GATE_RULES.each { |id, re| return id if q.match?(re) }
      nil
    end

    def self.instructions_block(question)
      pack = retrieve_pack(question)
      block =
        if pack[:zone] == :legacy
          legacy_instructions_block(pack[:sources])
        elsif pack[:sources].blank? || pack[:zone] == :empty
          NO_EVIDENCE_BLOCK.strip
        else
          lines =
            pack[:sources].each_with_index.map do |s, i|
              cat = s[:category].present? ? " [cat:#{s[:category]}]" : ""
              excerpt = s[:excerpt].present? ? "\n   excerpt: #{s[:excerpt]}" : ""
              "#{i + 1}. title: #{s[:title]} [via:#{s[:via]}]#{cat}#{excerpt}"
            end

          tpl = pack[:zone] == :weak ? WEAK_EVIDENCE_TEMPLATE : EVIDENCE_TEMPLATE
          format(tpl, lines: lines.join("\n")).strip
        end

      "#{block}\n\n#{forum_taxonomy_block}".strip
    end

    # Taxonomie publique du forum, injectée dans le bloc d'instructions : le LLM
    # peut nommer la bonne (sous-)catégorie quand il invite à poster, même sans
    # evidence probante. Cachée 12 h — les catégories bougent rarement.
    def self.forum_taxonomy_block
      Discourse.cache.fetch("dpec_taxonomy", expires_in: 12.hours) do
        cats =
          Category
            .where(read_restricted: false)
            .where.not(id: SiteSetting.uncategorized_category_id)
            .order(:position)
            .to_a
        by_parent = cats.group_by(&:parent_category_id)

        lines = ["## Forum categories (public — where discussions live)"]
        by_parent[nil].to_a.each do |parent|
          pdesc = CGI.unescapeHTML(parent.description.to_s.gsub(/<[^>]+>/, " ")).squish
          lines << "#{parent.name}#{pdesc.present? ? " — #{pdesc}" : ""}"
          by_parent[parent.id].to_a.each do |child|
            cdesc = CGI.unescapeHTML(child.description.to_s.gsub(/<[^>]+>/, " ")).squish
            lines << "  - #{child.name}#{cdesc.present? ? " — #{cdesc}" : ""}"
          end
        end
        lines.join("\n")
      end
    end

    def self.for_question(question)
      retrieve_pack(question)[:sources]
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations::Retrieval: #{e.class} #{e.message}")
      []
    end

    # --- variantes conversation-aware : reformulent le dernier message avec
    # l'historique (marque/matière/montage mentionnés plus tôt) avant retrieval.
    # Utilisées par PlaygroundHook et Sanitizer (mêmes deux points d'appel que
    # ci-dessus) ; instructions_block/for_question restent utilisables telles
    # quelles (question isolée, sans historique) pour l'éval (rag/eval/eval_full.rb).
    def self.instructions_block_for_post(post)
      instructions_block(effective_question(post))
    end

    def self.for_post(post)
      for_question(effective_question(post))
    end

    def self.effective_question(post)
      return "" if post.blank?

      # Mémoïsé par post : PlaygroundHook (génération) puis Sanitizer (for_post
      # + suggested_category) appellent tous effective_question — un seul appel
      # de condensation par message utilisateur au lieu de trois.
      Discourse.cache.fetch("dpec_effq:#{post.id}", expires_in: CACHE_TTL) do
        latest = post.raw.to_s.gsub(/<[^>]+>/, " ").squish
        condense_query(latest, history_for(post))
      end
    end

    def self.history_for(post)
      return [] if post.blank? || post.topic.blank?

      post
        .topic
        .posts
        .where("post_number < ?", post.post_number)
        .where("user_id > 0")
        .order(post_number: :desc)
        .limit(HISTORY_TURNS)
        .pluck(:raw)
        .reverse
        .map { |r| r.to_s.gsub(/<[^>]+>/, " ").squish }
        .reject(&:blank?)
    end

    # Réécrit le dernier message en requête autonome à partir de l'historique
    # (ex. "Ok, box calf goodyear" après "mes Carmina" → "entretien Carmina
    # box calf Goodyear"). Même LLM que la génération (qwen3:30b MoE, rapide
    # à ~3B actifs, think:false forcé) — indispo/erreur → dernier message tel quel.
    def self.condense_query(latest, history)
      return latest if history.blank?

      condense_via_llm(latest, history).presence || latest
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations::Retrieval condense: #{e.class} #{e.message}")
      latest
    end

    CONDENSE_SYSTEM_PROMPT = (
      "Tu réécris le dernier message d'une conversation de forum en UNE " \
      "requête de recherche autonome et complète, en français. Le dernier " \
      "message exprime le besoin principal : il doit dominer la requête. " \
      "L'historique ne sert qu'à le préciser — reprends les éléments déjà " \
      "mentionnés (marque, modèle, matière, montage) seulement s'ils restent " \
      "le sujet, et garde la hiérarchie : matière/montage/intention d'abord, " \
      "marque ensuite. Si le dernier message change clairement de sujet, ne " \
      "garde que le dernier message. Réponds UNIQUEMENT avec la requête " \
      "reformulée, une seule phrase, sans préambule ni guillemets."
    ).freeze

    def self.condense_via_llm(latest, history)
      url = SiteSetting.depiedencap_ai_citations_condense_llm_url.to_s.presence
      return nil if url.blank?

      convo = history.map { |h| "- #{h}" }.join("\n")
      body = {
        model: SiteSetting.depiedencap_ai_citations_condense_model.to_s.presence || "llama3.1:8b",
        messages: [
          { role: "system", content: CONDENSE_SYSTEM_PROMPT },
          { role: "user", content: "Historique :\n#{convo}\n\nDernier message : #{latest}" },
        ],
        max_tokens: CONDENSE_MAX_TOKENS,
        temperature: 0,
        # thinking désactivé : inutile pour une réécriture d'une phrase, et
        # qwen3 peut engloutir le budget de tokens dans un raisonnement vide
        # (observé avec qwen3:4b). Ignoré sans erreur par les modèles
        # non-thinking (llama).
        think: false,
      }

      conn =
        Faraday.new do |f|
          f.options.open_timeout = CONDENSE_OPEN_TIMEOUT
          f.options.timeout = CONDENSE_READ_TIMEOUT
        end
      resp =
        conn.post(url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = body.to_json
        end
      return nil unless resp&.status == 200

      text = JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s.strip
      text = text.gsub(%r{<think>.*?</think>}m, "").strip.gsub(/\A["“]|["”]\z/, "").strip
      # borne large : un texte anormalement long trahit un raisonnement non filtré, pas une requête
      text.presence if text.length.between?(3, 300)
    end

    # Résultat complet retrieval+classification, mis en cache : sources +
    # zone (:legacy | :empty | :weak | :ok) + score CE top-1 éventuel.
    # Clé de cache = la question elle-même (texte complet) — PAS un bucket
    # d'intention grossier : deux questions différentes ne doivent jamais
    # partager une entrée de cache (bug corrigé 17/09 : "goodyear" seul
    # suffisait à faire matcher deux questions sans rapport, cf. PLAN_RAG_PROD_VPS.md).
    def self.retrieve_pack(question)
      q = question.to_s.gsub(/<[^>]+>/, " ").squish
      return { sources: [], zone: :legacy } if q.blank?

      key = "depiedencap_ai_citations:v2:#{Digest::SHA1.hexdigest(q.downcase)}"
      Rails.cache.fetch(key, expires_in: CACHE_TTL) do
        pack = posts_pipeline? ? retrieve_posts_pack(q) : nil
        pack || { sources: retrieve(q), zone: :legacy }
      end
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations::Retrieval pack: #{e.class} #{e.message}")
      { sources: [], zone: :legacy }
    end

    # --- canal v2 : grain post + rerank -------------------------------------

    def self.posts_pipeline?
      return false unless SiteSetting.depiedencap_ai_citations_posts_pipeline
      return false unless defined?(DiscourseAi::Embeddings::Vector)
      return false unless SiteSetting.ai_embeddings_enabled

      posts_table_ready?
    rescue StandardError
      false
    end

    # Le canal posts exige des données — son activation avant la fin du
    # backfill retomberait sur du vide. Vérifié 1×/min, pas à chaque requête.
    def self.posts_table_ready?
      Rails.cache.fetch("depiedencap_ai_citations:posts_ready", expires_in: POSTS_ROWS_TTL) do
        ActiveRecord::Base
          .connection
          .select_value("SELECT 1 FROM ai_posts_embeddings LIMIT 1")
          .present?
      rescue StandardError
        false
      end
    end

    def self.retrieve_posts_pack(question)
      vector = DiscourseAi::Embeddings::Vector.instance
      vdef = vector.vdef
      qvec = vector.vector_from(question)
      return nil if qvec.blank?

      hits = post_candidates(qvec, vdef)
      return { sources: [], zone: :empty, ce: nil } if hits.blank?

      ranked, ce_top1 = rerank_or_dist(question, hits)
      return { sources: [], zone: :empty, ce: ce_top1 } if ranked.blank?

      zone =
        if ce_top1.nil?
          :ok # reranker down : ordre cosine seul (config B mesurée), pas de zone
        elsif ce_top1 < ABSTAIN_CE
          :empty
        elsif ce_top1 < WEAK_CE
          :weak
        else
          :ok
        end
      return { sources: [], zone: :empty, ce: ce_top1 } if zone == :empty

      sources =
        dedup_by_topic(ranked)
          .first(MAX_SOURCES)
          .map do |h|
            {
              title: h[:title],
              url: "/t/#{h[:slug]}/#{h[:topic_id]}/#{h[:post_number]}",
              excerpt: h[:raw_excerpt],
              category: h[:cat_label],
              category_id: h[:category_id],
              via: "posts",
            }
          end
      { sources: sources, zone: zone, ce: ce_top1 }
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations::Retrieval posts: #{e.class} #{e.message}")
      nil
    end

    # Cosine pgvector sur ai_posts_embeddings — même requête que l'éval, plus
    # les filtres prod : posts/Topics non supprimés, type regular, pas de MP,
    # pas de catégorie restreinte (le canal legacy passait par Guardian).
    def self.post_candidates(qvec, vdef)
      sql = <<~SQL
        SELECT e.post_id, p.topic_id, p.post_number, t.title, t.slug, p.raw,
               t.category_id,
               c.name AS cat_name, pc.name AS parent_cat_name,
               e.embeddings <=> '#{qvec}' AS dist
        FROM ai_posts_embeddings e
        JOIN posts p ON p.id = e.post_id
        JOIN topics t ON t.id = p.topic_id
        LEFT JOIN categories c ON c.id = t.category_id
        LEFT JOIN categories pc ON pc.id = c.parent_category_id
        WHERE e.model_id = #{vdef.id.to_i} AND e.strategy_id = #{vdef.strategy_id.to_i}
          AND p.deleted_at IS NULL AND p.post_type = 1
          AND t.deleted_at IS NULL AND t.archetype = 'regular'
          AND (
            t.category_id IS NULL
            OR NOT EXISTS (
              SELECT 1 FROM categories c
              WHERE c.id = t.category_id AND c.read_restricted
            )
          )
        ORDER BY e.embeddings <=> '#{qvec}'
        LIMIT #{POSTS_SQL_LIMIT}
      SQL

      ActiveRecord::Base.connection.execute(sql).to_a.map do |row|
        raw = row["raw"].to_s.gsub(/\s+/, " ").strip[0, 300]
        parent = row["parent_cat_name"].to_s.presence
        cat = row["cat_name"].to_s.presence
        {
          post_id: row["post_id"].to_i,
          topic_id: row["topic_id"].to_i,
          post_number: row["post_number"].to_i,
          slug: row["slug"],
          title: row["title"],
          category_id: row["category_id"].to_i,
          cat_label: [parent, cat].compact.join(" → "),
          dist: row["dist"].to_f,
          raw_excerpt: raw,
          ce_text: "#{row["title"]}. #{raw}",
        }
      end
    end

    # Rerank cross-encoder (service TEI sur le mini PC, endpoint /rerank).
    # TEI renvoie un score sigmoïdé [0,1] → reconverti en logit pour garder
    # les seuils mesurés en éval (logits bruts sentence-transformers).
    # Indisponible/timeout → ([hits par dist], nil) : l'appelant dégrade.
    def self.rerank_or_dist(question, hits)
      texts = hits.map { |h| h[:ce_text] }
      scores = rerank_scores(question, texts)
      return [hits.sort_by { |h| h[:dist] }, nil] if scores.nil?

      ranked =
        hits
          .zip(scores)
          .map { |h, s| h.merge(ce: sigmoid_to_logit(s)) }
          .sort_by { |h| -h[:ce] }
      [ranked, ranked.first[:ce]]
    end

    def self.rerank_scores(question, texts)
      url = rerank_url
      return nil if url.blank? || texts.blank?

      conn =
        Faraday.new do |f|
          f.options.open_timeout = RERANK_OPEN_TIMEOUT
          f.options.timeout = RERANK_READ_TIMEOUT
        end
      resp =
        conn.post(url) do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = { query: question, texts: texts }.to_json
        end
      return nil unless resp&.status == 200

      pairs = JSON.parse(resp.body)
      return nil unless pairs.is_a?(Array)

      by_index = pairs.to_h { |p| [p["index"].to_i, p["score"].to_f] }
      texts.each_index.map { |i| by_index[i] }
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations::Retrieval rerank: #{e.class} #{e.message}")
      nil
    end

    def self.rerank_url
      SiteSetting.depiedencap_ai_citations_rerank_url.to_s.presence
    end

    def self.sigmoid_to_logit(score)
      s = score.to_f.clamp(1e-6, 1.0 - 1e-6)
      Math.log(s / (1.0 - s))
    end

    def self.dedup_by_topic(hits)
      seen = {}
      hits.each { |h| seen[h[:topic_id]] ||= h }
      seen.values
    end

    # --- chemin legacy (inchangé — fallback + référence prod) -----------------

    def self.legacy_instructions_block(sources)
      if sources.blank?
        return <<~TXT.strip
          ## STABLE FORUM EVIDENCE
          No sufficiently relevant forum threads were retrieved.
          Reply briefly in the user's language that you lack solid forum evidence for this question.
          Invite them to post in a fitting category. Do NOT invent threads, brands, or /t/ URLs.
          Do NOT write ### Sources. Do NOT call tools.
        TXT
      end

      lines =
        sources.each_with_index.map do |s, i|
          n = i + 1
          excerpt = s[:excerpt].present? ? "\n   excerpt: #{s[:excerpt]}" : ""
          via = s[:via].present? ? " [via:#{s[:via]}]" : ""
          "#{n}. title: #{s[:title]}#{via}#{excerpt}"
        end

      <<~TXT.strip
        ## STABLE FORUM EVIDENCE (authoritative — do not ignore)
        Hybrid retrieval (keyword + semantic). Answer ONLY from this evidence.

        ### Citation rules (strict)
        - Cite ONLY bare markers: [[1]], [[2]], [[3]] … matching Evidence numbers.
        - MUST cite [[1]] in the first sentence (best match / definitional thread).
        - Then [[2]], [[3]] in that order. Do not skip [[1]]. Do not jump to [[5]] before [[1]]–[[3]].
        - 3 to 5 citations. NEVER write URLs or /t/… yourself.
        - NEVER invent brands/titles/jargon absent from titles/excerpts.
        - Do NOT call tools.

        ### Output format (mandatory)
        1) Short answer body ONLY with [[n]] citations. NO discussion lists. NO /t/ URLs.
        2) Do NOT write ### Sources or ### Pour aller plus loin yourself.
        3) Do NOT write a pending/placeholder line. Stop after the body.

        ### Evidence
        #{lines.join("\n")}
      TXT
    end

    def self.normalize_key(question)
      q = question.to_s
      INTENT_QUERIES.each_with_index do |(rx, queries), idx|
        return "intent:#{idx}:#{queries.first}" if q.match?(rx)
      end

      q
        .downcase
        .gsub(/[^\p{L}\p{N}\s]/u, " ")
        .split
        .reject { |w| w.length < 2 || STOPWORDS.include?(w) }
        .sort
        .join(" ")
    end

    def self.canonical_query(question)
      queries_for(question).first || normalize_key(question).split.first(5).join(" ")
    end

    def self.queries_for(question)
      q = question.to_s
      INTENT_QUERIES.each do |rx, queries|
        return queries.dup if q.match?(rx)
      end
      keywords =
        q
          .downcase
          .gsub(/[^\p{L}\p{N}\s\-]/u, " ")
          .split
          .reject { |w| w.length < 3 || STOPWORDS.include?(w) }
          .uniq
          .first(6)
      [keywords.join(" ")].reject(&:blank?)
    end

    def self.question_keywords(question)
      question
        .to_s
        .downcase
        .gsub(/[^\p{L}\p{N}\s\-]/u, " ")
        .split
        .reject { |w| w.length < 3 || STOPWORDS.include?(w) }
        .uniq
    end

    def self.retrieve(question)
      keywords = question_keywords(question)
      distinctive = keywords.select { |w| w.length >= 6 }
      candidates = {}

      # 1) Classic keyword Search
      queries_for(question).each_with_index do |query, qidx|
        begin
          results = Search.execute(query, guardian: Guardian.new, type_filter: "topic")
          Array(results&.posts).first(25).each_with_index do |post, rank|
            add_candidate!(
              candidates,
              post,
              keywords,
              distinctive,
              base: 40 - rank,
              via: "kw",
              query_boost: (3 - qidx),
            )
          end
        rescue StandardError => e
          Rails.logger.warn("DepiedencapAiCitations classic search: #{e.class} #{e.message}")
        end
      end

      # 2) Semantic (pgvector) — needs embeddings service up; hyde:false = embed the query
      semantic_posts(question).each_with_index do |post, rank|
        add_candidate!(
          candidates,
          post,
          keywords,
          distinctive,
          base: 35 - rank,
          via: "sem",
          query_boost: 2,
        )
      end

      candidates
        .values
        .select { |h| h[:score] >= MIN_SCORE }
        .sort_by { |h| [-h[:score], h[:title].to_s.downcase] }
        .first(MAX_SOURCES)
        .map { |h| h.except(:score) }
    end

    def self.semantic_posts(question)
      return [] unless defined?(DiscourseAi::Embeddings::SemanticSearch)
      return [] unless SiteSetting.ai_embeddings_enabled

      query = canonical_query(question).presence || question
      ss = DiscourseAi::Embeddings::SemanticSearch.new(Guardian.new)
      # hyde:false → use real query embedding (no extra LLM call)
      Array(ss.search_for_topics(query, 1, hyde: false)).first(20)
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations semantic search: #{e.class} #{e.message}")
      []
    end

    def self.add_candidate!(candidates, post, keywords, distinctive, base:, via:, query_boost: 0)
      topic = post.topic
      return if topic.blank? || topic.title.to_s.match?(WELCOME_TITLE_RE)

      title_score = relevance_score(topic.title, keywords, distinctive)
      # Same title gate for keyword AND semantic — no excerpt-only soft admits
      return if title_score <= 0

      id = topic.id
      entry =
        candidates[id] ||= {
          title: topic.title,
          url: "/t/#{topic.slug}/#{topic.id}",
          excerpt: excerpt_for(post),
          score: 0,
          via: via,
        }

      # Hybrid boost: found by both channels
      hybrid = entry[:via] != via ? 12 : 0
      entry[:via] = [entry[:via], via].uniq.join("+")
      entry[:score] += base + title_score + query_boost + hybrid
      entry[:excerpt] = excerpt_for(post) if entry[:excerpt].blank?
    end

    def self.relevance_score(title, keywords, distinctive)
      t = title.to_s.downcase
      return 0 if t.blank?

      if distinctive.present?
        return 0 unless distinctive.any? { |w| t.include?(w) || stem_match?(t, w) }
      end

      score = 0
      keywords.each do |w|
        if t.include?(w)
          score += w.length >= 6 ? 10 : 3
        elsif stem_match?(t, w)
          score += w.length >= 6 ? 8 : 2
        end
      end

      qblob = keywords.join(" ")
      if qblob.match?(/terme|d[eé]finition|expliquer|qu.est/) ||
           keywords.any? { |w| w.end_with?("philie") }
        score += 15 if t.match?(/terme|d[eé]finition|sens|signifie/i)
        score += 5 if t.match?(/\Adu terme|\Ale\b/i)
      end

      score
    end

    def self.stem_match?(title, word)
      stem = word.sub(/ie\z/, "").sub(/iques?\z/, "").sub(/euse?\z/, "").sub(/s\z/, "")
      return false if stem.length < 4
      title.include?(stem)
    end

    def self.excerpt_for(post)
      raw = post.raw.to_s
      raw = raw.gsub(/\[quote[^\]]*\].*?\[\/quote\]/im, " ")
      raw = raw.gsub(/!\[[^\]]*\]\([^)]+\)/, " ")
      raw = raw.gsub(/\[[^\]]*\]\([^)]+\)/, " ")
      raw = raw.gsub(/https?:\/\/\S+/i, " ")
      raw = raw.gsub(/\[.*?\]/, " ")
      raw = raw.gsub(/\s+/, " ").squish
      return "" if raw.blank?
      raw.truncate(EXCERPT_LEN, separator: " ", omission: "…")
    end
  end
end
