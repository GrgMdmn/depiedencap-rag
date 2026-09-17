# frozen_string_literal: true

class DepiedencapAiLlmWarmupController < ApplicationController
  requires_login
  skip_before_action :check_xhr

  def show
    raise Discourse::InvalidAccess unless SiteSetting.depiedencap_ai_citations_enabled
    # Évite le polling global : warmup réservé au compte démo chatbot.
    raise Discourse::InvalidAccess unless current_user&.username == "demo"

    render json: DepiedencapAiCitations::WarmupStatus.fetch(use_cache: false)
  end
end
