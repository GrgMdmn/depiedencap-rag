# frozen_string_literal: true

module DepiedencapAiCitations
  # Whitelist /t/ URLs that exist in Postgres. LLM never gets the last word on links.
  class Sanitizer
    MD_LINK_RE = %r{\[([^\]]*)\]\((?:https?://[^/\s\)]+)?(/t/[^)\s]+)\)}i
    BARE_PATH_RE = %r{(?<!\]\()/t/[a-z0-9\-%]+/\d+(?:/\d+)?}i
    BARE_CITE_RE = /\[\[(\d+)\]\](?!\()/
    CITE_MD_RE = %r{\[\[(\d+)\]\]\((?:https?://[^/\s\)]+)?(/t/[^)\s]+)\)}i

    GUIDE_PERSONA_NAME = "Guide Depiedencap"
    CORE_BOT_USERNAMES = %w[system discobot].freeze

    def self.sanitize!(post)
      return if post.blank? || post.raw.blank?
      return unless guide_bot_post?(post)
      return unless post.topic&.private_message?

      # LLM down / maintenance : le retriever local a pu trouver des fils,
      # mais il n'y a pas de réponse générée → pas de Sources ni CTA.
      if unavailable_reply?(post.raw)
        keep_unavailable_only!(post)
        return
      end

      return if post.custom_fields["depiedencap_ai_citations"] == "t"

      question = user_question(post)
      user_post = originating_user_post(post)
      # Mêmes reformulation/cache que ce que le LLM a vu (PlaygroundHook) : sans
      # ça, la question réécrite par condense_query pour la génération et la
      # question brute utilisée ici pour les citations divergeraient.
      sources = user_post ? Retrieval.for_post(user_post) : []
      raw = post.raw.to_s.dup

      raw = expand_bare_cites(raw, sources)
      raw = force_cite_urls(raw, sources)
      raw = ensure_primary_citation(raw, sources)
      raw = strip_fake_md_links(raw)
      raw = raw.gsub(BARE_PATH_RE, "")
      raw = strip_llm_source_lists(raw)
      raw = strip_section(raw, "Sources")
      raw = strip_section(raw, "Pour aller plus loin")
      raw = raw.gsub(/\[\s*\]/, "").gsub(/ +\n/, "\n").gsub(/\n{3,}/, "\n\n").strip

      _cited, raw = renumber_citations_by_appearance(raw, sources)
      raw = glue_adjacent_citations(raw)
      raw = tidy_stripped_cites(raw)
      raw = restore_emoji_shortcode_spaces(raw)

      parts = [raw]
      # Pas de liste « ### Sources » : les [[n]] du corps sont déjà des liens
      # cliquables — la liste doublait les mêmes fils sans valeur ajoutée.
      parts << (sources.present? ? format_cta(sources, question) : abstain_cta(question))
      new_raw = parts.join("\n\n").gsub(/\n{3,}/, "\n\n").strip
      return if new_raw == post.raw.to_s.strip

      post.revise(
        Discourse.system_user,
        { raw: new_raw },
        bypass_bump: true,
        skip_validations: true,
        skip_revision: true,
      )
      post.custom_fields["depiedencap_ai_citations"] = "t"
      post.save_custom_fields
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations::Sanitizer: #{e.class} #{e.message}")
    end

    def self.expand_bare_cites(raw, sources)
      return raw if sources.blank?

      raw.gsub(BARE_CITE_RE) do
        src = sources[Regexp.last_match(1).to_i - 1]
        src && topic_exists?(src[:url]) ? "[[#{Regexp.last_match(1)}]](#{canonical(src[:url])})" : ""
      end
    end

    def self.force_cite_urls(raw, sources)
      return raw if sources.blank?

      raw.gsub(CITE_MD_RE) do
        src = sources[Regexp.last_match(1).to_i - 1]
        src && topic_exists?(src[:url]) ? "[[#{Regexp.last_match(1)}]](#{canonical(src[:url])})" : ""
      end
    end

    # Si le meilleur fil (évidence 1) n'est pas cité, l'injecter en première citation du corps.
    def self.ensure_primary_citation(raw, sources)
      return raw if raw.blank? || sources.blank?

      primary = sources.first
      return raw unless primary && topic_exists?(primary[:url])

      pid = topic_id(primary[:url])
      already =
        raw.scan(CITE_MD_RE).any? { |_n, path| topic_id(path) == pid }
      return raw if already

      marker = "[[1]](#{canonical(primary[:url])})"
      idx = raw.index(CITE_MD_RE)
      if idx
        raw.dup.tap { |s| s.insert(idx, "#{marker} ") }
      elsif raw.sub!(/\A([^.!?]+[.!?])/, "\\1 #{marker}")
        raw
      else
        "#{raw} #{marker}"
      end
    end

    # [[n]] du corps → 1, 2, 3… dans l'ordre d'apparition. Sources = uniquement ces fils.
    def self.renumber_citations_by_appearance(raw, allowed_sources)
      by_topic = {}
      order = []

      raw.scan(CITE_MD_RE) do |_num, path|
        path = canonical(path)
        next unless topic_exists?(path)
        tid = topic_id(path)
        next if tid <= 0 || by_topic.key?(tid)

        meta =
          Array(allowed_sources).find { |s| topic_id(s[:url]) == tid } ||
            {
              title: Topic.find_by(id: tid)&.title || path,
              url: path,
              excerpt: nil,
            }
        by_topic[tid] = {
          title: meta[:title],
          url: canonical(meta[:url] || path),
          excerpt: meta[:excerpt],
        }
        order << tid
      end

      return [Array(allowed_sources).first(6), raw] if order.blank?

      new_index = {}
      order.each_with_index { |tid, i| new_index[tid] = i + 1 }

      rewritten =
        raw.gsub(CITE_MD_RE) do
          path = canonical(Regexp.last_match(2))
          tid = topic_id(path)
          n = new_index[tid]
          n ? "[[#{n}]](#{canonical(path)})" : ""
        end

      [order.map { |tid| by_topic[tid] }, rewritten]
    end

    def self.strip_fake_md_links(raw)
      raw.gsub(MD_LINK_RE) do
        title, path = Regexp.last_match(1), canonical(Regexp.last_match(2))
        if title.match?(/\A\d+\z/)
          topic_exists?(path) ? "[[#{title}]](#{path})" : ""
        elsif topic_exists?(path)
          "[#{Topic.find_by(id: topic_id(path))&.title || title}](#{path})"
        else
          ""
        end
      end
    end

    def self.strip_llm_source_lists(raw)
      raw.gsub(
        /
          (?:^|\n+)
          (?:Voici\s+(?:quelques\s+)?discussions|Discussions?\s+pertinentes|
             Pour\s+explorer|Vous\s+pouvez\s+consulter)
          [^\n]*\n
          (?:(?:\s*(?:[-*]|\d+\.)\s+[^\n]*\n)*)
        /xim,
        "\n",
      )
    end

    def self.strip_section(raw, heading)
      raw.gsub(
        /(?:^|\n+)(?:\#{1,3}\s*)?#{Regexp.escape(heading)}\b[^\n]*\n(?:(?!\n\#{1,3}\s)[^\n]*\n?)*/im,
        "\n",
      )
    end

    def self.format_cta(sources, question)
      lines = ["### Pour aller plus loin"]
      cta_sources(sources).each do |s|
        lines << "- [#{s[:title]}](#{canonical(s[:url])}) : #{cta_invitation(s)}"
      end
      cat = suggested_category(question)
      lines << "- [#{cat[:label]}](#{cat[:path]}) : #{cat[:cta]}" if cat
      lines.join("\n")
    end

    # 3 fils de natures différentes si possible (définition / récit / pratique…).
    def self.cta_sources(sources)
      picked = []
      seen = {}
      Array(sources).each do |s|
        kind = source_kind(s)
        next if seen[kind]
        seen[kind] = true
        picked << s
        break if picked.size >= 3
      end
      Array(sources).each do |s|
        break if picked.size >= 3
        picked << s unless picked.include?(s)
      end
      picked
    end

    def self.source_kind(source)
      t = source[:title].to_s
      return :definition if t.match?(/terme|d[eé]finition|sens|signifie/i)
      return :entretien if t.match?(/entretien|cirage|patine|glac|m[eé]t[eé]o|neige|sel|boue|tr[ée]pointe/i)
      return :local if t.match?(/r[eé]gion|ville|urgent|angoul|paris|lyon|contact/i)
      return :collab if t.match?(/collaboration|artisan|valet/i)
      return :recit if t.match?(/toujours|passion|avis|pourquoi/i)
      :other
    end

    # Pourquoi ce fil + quoi y poster. Titre + extrait déjà indexés — pas un 2ᵉ appel LLM.
    def self.cta_invitation(source)
      excerpt = source[:excerpt].to_s.gsub(/\s+/, " ").squish
      welcome_excerpt =
        excerpt.match?(
          /
            \A\s*(bonjour|bonsoir|hello|salut)|
            nouveau\s+venu|je\s+m['’]appelle|je\s+me\s+pr[ée]sente
          /ix,
        )
      hook =
        if excerpt.length >= 40 && !welcome_excerpt
          "« #{excerpt.truncate(90, separator: " ", omission: "…")} »"
        end

      case source_kind(source)
      when :definition
        why = "C’est le fil où le mot est discuté"
        why += " — #{hook}" if hook
        "#{why}. Tu peux y dire comment tu l’as rencontré, ou ce qu’il recouvre pour toi."
      when :entretien
        why = "Retours concrets d’entretien (climat, produits, gestes)"
        why += " ; on y lit #{hook}" if hook
        "#{why}. Une photo ou le produit que tu as utilisé y sera utile."
      when :local
        "Fil pour se croiser près d’un coin de France. Utile si tu es dans le secteur, ou pour proposer le tien."
      when :collab
        why = "Un projet / artisan présenté aux membres"
        why += " (#{hook})" if hook
        "#{why}. Un avis d’usage ou une question à l’artisan a sa place."
      when :recit
        why = "Récits personnels autour des souliers"
        why += " — #{hook}" if hook
        "#{why}. Tu peux y raconter ce qui t’a accroché (une paire, un rituel, un artisan)."
      else
        if hook
          "On y lit #{hook}. Une question ou un retour d’expérience (ce qui colle à ton cas) y trouvera sa place."
        else
          "Fil proche de ta question. Pose une précision concrète plutôt qu’un « +1 »."
        end
      end
    end

    def self.abstain_cta(question = nil)
      cat = suggested_category(question)
      if cat
        <<~MD.strip
          ### Pour aller plus loin
          Je n’ai pas trouvé de fil suffisamment proche sur le forum. Tu peux poser la question dans [#{cat[:label]}](#{cat[:path]}) (budget, usage, pointure).
        MD
      else
        <<~MD.strip
          ### Pour aller plus loin
          Je n’ai pas trouvé de fil suffisamment proche sur le forum. Tu peux ouvrir un sujet dans la catégorie qui correspond le mieux à ta question.
        MD
      end
    end

    def self.suggested_category(question)
      q = question.to_s
      spec =
        if q.match?(/entretien|cirage|patine|glac|tr[ée]pointe/i)
          {
            parent: "Les souliers",
            child: "Entretien, réparation, glaçage et patine",
            cta: "ouvre un sujet avec photos / produits si ton cas n’y est pas.",
          }
        else
          {
            parent: "Les souliers",
            child: "Le prêt à chausser",
            cta: "si aucun de ces fils ne colle à *ton* cas, ouvre un sujet (usage, contraintes, ce que tu cherches).",
          }
        end

      cat = find_named_category(spec[:parent], spec[:child])
      return nil unless cat

      {
        label: "#{spec[:parent]} → #{cat.name}",
        path: category_href(cat),
        cta: spec[:cta],
      }
    end

    def self.find_named_category(parent_name, child_name)
      parent = Category.find_by(name: parent_name)
      return nil unless parent

      Category.find_by(name: child_name, parent_category_id: parent.id)
    end

    def self.category_href(category)
      return nil if category.blank?

      slugs = []
      slugs << category.parent_category.slug if category.parent_category
      slugs << category.slug
      "/c/#{slugs.join("/")}/#{category.id}"
    end

    def self.guide_user_id
      return nil unless defined?(AiAgent)

      AiAgent.find_by(name: GUIDE_PERSONA_NAME)&.user_id
    end

    def self.unavailable_reply?(raw)
      Unavailable.reply?(raw)
    end

    # Message d'indispo seul. Auto-répare les posts déjà pollués (Sources + CTA).
    def self.keep_unavailable_only!(post)
      target = Unavailable::MESSAGE
      current = post.raw.to_s.strip
      unless current == target
        post.revise(
          Discourse.system_user,
          { raw: target },
          bypass_bump: true,
          skip_validations: true,
          skip_revision: true,
        )
      end
      post.custom_fields["depiedencap_ai_citations"] = "t"
      post.save_custom_fields
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations keep_unavailable: #{e.class} #{e.message}")
    end

    # Posts Guide déjà sanitizés pendant une indispo (footer RAG collé au message humoristique).
    def self.revert_unavailable_footers!
      Post
        .where("raw LIKE ?", "%#{sanitize_sql_like(Unavailable::FINGERPRINT)}%")
        .find_each do |post|
          next unless guide_bot_post?(post)
          next unless post.topic&.private_message?

          keep_unavailable_only!(post)
        end
    end

    def self.sanitize_sql_like(value)
      ActiveRecord::Base.sanitize_sql_like(value.to_s)
    end
    private_class_method :sanitize_sql_like

    # discobot et system ont aussi un id négatif — ne pas les traiter comme le Guide.
    def self.guide_bot_post?(post)
      return false if post.blank?

      uid = post.user_id.to_i
      return false unless uid.negative?
      return false if uid == Discourse::SYSTEM_USER_ID
      return false if CORE_BOT_USERNAMES.include?(post.user&.username.to_s.downcase)

      gid = guide_user_id
      gid.present? && uid == gid.to_i
    end

    # Posts discobot déjà réécrits par l’ancien hook (footer RAG). À lancer une fois en rails runner.
    def self.revert_nonguide_footers!
      PostCustomField.where(name: "depiedencap_ai_citations", value: "t").find_each do |pcf|
        post = Post.find_by(id: pcf.post_id)
        next if post.blank? || guide_bot_post?(post)

        stripped = strip_section(post.raw.to_s, "Pour aller plus loin")
        stripped = strip_section(stripped, "Sources")
        stripped = restore_emoji_shortcode_spaces(stripped)
        stripped = stripped.gsub(/\n{3,}/, "\n\n").strip
        next if stripped.blank? || stripped == post.raw.to_s.strip

        post.revise(
          Discourse.system_user,
          { raw: stripped },
          bypass_bump: true,
          skip_validations: true,
          skip_revision: true,
        )
        post.custom_fields.delete("depiedencap_ai_citations")
        post.save_custom_fields
      end
    end

    def self.originating_user_post(post)
      return nil if post.blank? || post.topic.blank?

      post
        .topic
        .posts
        .where("post_number < ?", post.post_number)
        .where("user_id > 0")
        .order(post_number: :desc)
        .first
    end

    def self.user_question(post)
      originating_user_post(post)
        &.raw
        .to_s
        .gsub(/<[^>]+>/, " ")
        .squish
    end

    def self.canonical(path)
      path = path.to_s.split("#").first.split("?").first.sub(%r{\Ahttps?://[^/]+}i, "")
      path = "/#{path}" unless path.start_with?("/")
      path[%r{\A/t/[^/]+/\d+(?:/\d+)?}i, 0] || path
    end

    def self.topic_id(path)
      canonical(path).to_s[%r{/t/[^/]+/(\d+)}, 1].to_i
    end

    def self.post_number(path)
      path.to_s[%r{/t/[^/]+/\d+/(\d+)}i, 1].to_i
    end

    def self.topic_exists?(path)
      tid = topic_id(path)
      return false unless tid.positive? && Topic.exists?(id: tid)
      n = post_number(path)
      n.zero? || Post.exists?(topic_id: tid, post_number: n)
    end

    # Pas de virgule entre deux notes : `[[2]], [[3]]` → `[[2]] [[3]]`.
    def self.glue_adjacent_citations(raw)
      raw.to_s.gsub(/(\]\](?:\([^)]+\))?)\s*,\s*(?=\[\[)/, '\1 ')
    end

    # Virgules orphelines après retrait des [[n]] : `James ,. ` → `James.`
    # Ne touche pas aux listes réelles (`Weston, Church`).
    # Ne pas coller l’espace avant `:` : ça casse les shortcodes (`un :gift:` → `un:gift:`).
    def self.tidy_stripped_cites(s)
      s = s.to_s
      s = s.gsub(/\s*,(?:\s*,)*\s*(?=[.,;!?»"”)\]]|<|\z)/, "")
      s.gsub(/[ \t]+\n/, "\n").gsub(/ {2,}/, " ").gsub(/ +([.,;!?])/, '\1').gsub(/ :\s*\./, ".")
    end

    # `un:gift:` / `trouvé:tada:` après un tidy trop zélé. Pas les heures (`12:30`).
    def self.restore_emoji_shortcode_spaces(raw)
      raw.to_s.gsub(/(?<=\p{L})(:[a-z0-9_+-]+:)/i, ' \1')
    end

    # Pendant le stream : masquer [[n]] (numéros encore faux). Le sanitizer les repose ensuite.
    def self.strip_stream_markers(text)
      s = text.to_s
      s = s.gsub(/\[\[\d+\]\](?:\([^)]*\))?/, "")
      s = s.sub(/\[\[[\d]*\]?(?:\([^)]*)?\z/, "")
      tidy_stripped_cites(s)
    end

    # publish_final_update envoie du HTML déjà cooké (texte complet + [[n]]).
    # On retire les marqueurs sans recuire un chunk de stream en retard.
    def self.strip_cooked_markers(html)
      tidy_stripped_cites(html.to_s.gsub(/\[\[\d+\]\](?:\([^)]*\))?/, ""))
    end
  end
end
