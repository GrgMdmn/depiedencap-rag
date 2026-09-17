# frozen_string_literal: true

# name: depiedencap-ai-citations
# version: 0.2.0
# authors: Depiedencap
# required_version: 3.2.0
# about: RAG mince prod — retrieval hybride + citations whitelist. Proxy cold-start LLM. Pas de JS plugin.

enabled_site_setting :depiedencap_ai_citations_enabled

after_initialize do
  require_relative "lib/unavailable"
  require_relative "lib/retrieval"
  require_relative "lib/sanitizer"
  require_relative "lib/playground"
  require_relative "lib/demo_purge"
  require_relative "lib/warmup_status"
  require_relative "app/jobs/regular/depiedencap_sanitize_ai_citations"
  require_relative "app/controllers/depiedencap_ai_demo_purge_controller"
  require_relative "app/controllers/depiedencap_ai_llm_warmup_controller"

  Discourse::Application.routes.append do
    post "/depiedencap-ai/purge-demo" => "depiedencap_ai_demo_purge#purge"
    get "/depiedencap-ai/llm-warmup" => "depiedencap_ai_llm_warmup#show"
  end

  # Chaque visite de l’URL secrète = logout + login demo → inbox vide.
  DiscourseEvent.on(:user_logged_in) do |user|
    next unless SiteSetting.depiedencap_ai_citations_enabled
    next unless DepiedencapAiCitations::DemoPurge.demo_user?(user)

    DepiedencapAiCitations::DemoPurge.wipe!(user)
  end

  # Uniquement le persona Guide Depiedencap. discobot / system ont aussi
  # user_id < 0 : un filtre trop large leur collait le footer RAG en onboarding.
  DiscourseEvent.on(:post_created) do |post|
    next unless SiteSetting.depiedencap_ai_citations_enabled
    next unless DepiedencapAiCitations::Sanitizer.guide_bot_post?(post)
    next unless post.topic&.private_message?
    next if post.raw.blank? || post.raw.to_s.strip.length < 40
    next if DepiedencapAiCitations::Unavailable.reply?(post.raw)
    next if post.custom_fields["depiedencap_ai_citations"] == "t"

    Jobs.enqueue_in(2.seconds, :depiedencap_sanitize_ai_citations, post_id: post.id)
  end

  DiscourseAi::AiBot::Playground.prepend(DepiedencapAiCitations::PlaygroundHook)
  Post.prepend(DepiedencapAiCitations::PostReviseDeferCites)

  # Filet Discourse AI : reply_error sans dump TCP. Backend DiscourseI18n ignore store_translations.
  if defined?(TranslationOverride)
    msg = DepiedencapAiCitations::Unavailable::MESSAGE
    key = "discourse_ai.ai_bot.reply_error"
    %w[fr en].each do |locale|
      current = TranslationOverride.find_by(locale: locale, translation_key: key)
      next if current&.value.to_s.strip == msg

      TranslationOverride.upsert!(locale, key, msg)
    end
  end
end
