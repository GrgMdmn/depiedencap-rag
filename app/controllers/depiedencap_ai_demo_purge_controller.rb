# frozen_string_literal: true

class DepiedencapAiDemoPurgeController < ApplicationController
  requires_login
  skip_before_action :check_xhr

  def purge
    raise Discourse::InvalidAccess unless SiteSetting.depiedencap_ai_citations_enabled
    raise Discourse::InvalidAccess unless DepiedencapAiCitations::DemoPurge.demo_user?(current_user)

    deleted = DepiedencapAiCitations::DemoPurge.wipe!(current_user)
    render json: { success: true, deleted: deleted }
  end
end
