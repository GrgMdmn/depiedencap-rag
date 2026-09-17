# frozen_string_literal: true

module DepiedencapAiCitations
  # Signature alignée sur Post#revise (updated_by, changes, opts).
  # Pendant le revise Discourse AI de fin de stream : enregistrer le brut (avec [[n]])
  # et sauver une version SANS marqueurs — le client ne voit pas l’étape [[2]] [[5]].
  module PostReviseDeferCites
    def revise(updated_by, changes = {}, opts = {}, **kwargs)
      opts = opts.merge(kwargs) if kwargs.any?
      if Thread.current[:dpec_ai_defer_cites] && changes.is_a?(Hash) && changes[:raw].present?
        Thread.current[:dpec_ai_raw_full] = changes[:raw].to_s
        changes =
          changes.merge(raw: Sanitizer.strip_stream_markers(changes[:raw]))
      end
      super(updated_by, changes, opts)
    end
  end

  module PlaygroundHook
    def reply_to(post, custom_instructions: nil, **kwargs, &blk)
      stabilize = stabilize?(post)

      # Gate d'entrée : réponse fixe sans appel LLM (pipeline v2, mesuré).
      if stabilize && SiteSetting.depiedencap_ai_citations_input_gate &&
           DepiedencapAiCitations::Retrieval.gate_match(post.raw)
        publish_gate_decline!(post)
        return nil
      end

      if stabilize && DepiedencapAiCitations::WarmupStatus.unavailable?
        publish_unavailable!(post)
        return nil
      end

      if stabilize
        block = DepiedencapAiCitations::Retrieval.instructions_block_for_post(post)
        custom_instructions = [custom_instructions, block].compact.join("\n\n") if block.present?
        Thread.current[:dpec_ai_defer_cites] = true
        Thread.current[:dpec_ai_raw_full] = nil
      end

      result = nil
      error = nil
      begin
        result = super(post, custom_instructions: custom_instructions, **kwargs, &blk)
      rescue StandardError => e
        error = e
        Rails.logger.warn("DepiedencapAiCitations::PlaygroundHook: #{e.class} #{e.message}")
      ensure
        Thread.current[:dpec_ai_defer_cites] = false
      end

      apply_sanitize!(post) if stabilize && error.nil?
      Thread.current[:dpec_ai_raw_full] = nil

      if error
        if stabilize &&
             (
               DepiedencapAiCitations::Unavailable.connection_error?(error) ||
                 bot_post_is_unavailable?(post)
             )
          publish_unavailable!(post)
          return nil
        end
        raise error
      end

      result
    end

    # Même requête HTTP que le post utilisateur : pas de job Sidekiq, pas de stream.
    def schedule_bot_reply(post, authorization_user: post.user)
      if stabilize?(post)
        if SiteSetting.depiedencap_ai_citations_input_gate &&
             DepiedencapAiCitations::Retrieval.gate_match(post.raw)
          publish_gate_decline!(post)
          return
        end
        if DepiedencapAiCitations::WarmupStatus.unavailable?
          publish_unavailable!(post)
          return
        end
      end

      super
    end

    # Stream = autre thread. On masque [[n]] d’après le post, pas Thread.current.
    def publish_update(bot_reply_post, payload:, user_ids:, group_ids:)
      if strip_stream_for?(bot_reply_post) && payload
        payload = payload.dup
        if payload[:raw].present?
          @dpec_full_reply = payload[:raw]
          payload[:raw] = Sanitizer.strip_stream_markers(payload[:raw])
        end
        if payload[:cooked].present?
          payload[:cooked] = Sanitizer.strip_cooked_markers(payload[:cooked])
        end
      end
      super
    end

    def publish_final_update(reply_post, user_ids:, group_ids:)
      # Discourse cook le brut LLM complet (avec [[2]] [[5]]) puis publie done:true
      # AVANT le revise. C’est l’étape intermédiaire à sauter. Le PostStreamer
      # jette le dernier chunk (finish skip_callback: false) : ne pas recuire
      # @dpec_full_reply, trop court.
      if strip_stream_for?(reply_post) && reply_post.cooked.present?
        reply_post.cooked = Sanitizer.strip_cooked_markers(reply_post.cooked)
      end
      super
    end

    private

    def bot_post_is_unavailable?(user_post)
      guide_id = DepiedencapAiCitations::Sanitizer.guide_user_id
      return false if guide_id.blank?

      bot_post = user_post.topic.posts.where(user_id: guide_id).order(post_number: :desc).first
      return false if bot_post.blank?

      DepiedencapAiCitations::Unavailable.reply?(bot_post.raw) ||
        DepiedencapAiCitations::Unavailable.reply?(@dpec_full_reply)
    end

    def publish_unavailable!(user_post)
      publish_canned_reply!(user_post, DepiedencapAiCitations::Unavailable::MESSAGE)
    end

    # Réponse fixe du gate d'entrée (hors-rôle / dangereux) — pas de LLM.
    def publish_gate_decline!(user_post)
      publish_canned_reply!(user_post, DepiedencapAiCitations::Retrieval::GATE_DECLINE_MSG)
    end

    def publish_canned_reply!(user_post, msg)
      guide_id = DepiedencapAiCitations::Sanitizer.guide_user_id
      return if guide_id.blank?

      bot_user = User.find_by(id: guide_id)
      return if bot_user.blank?

      bot_post = user_post.topic.posts.where(user_id: guide_id).order(post_number: :desc).first
      reuse_streaming_post =
        bot_post &&
          bot_post.post_number.to_i > user_post.post_number.to_i &&
          (
            bot_post.raw.blank? ||
              DepiedencapAiCitations::Unavailable.reply?(bot_post.raw)
          )

      if reuse_streaming_post
        bot_post.revise(
          bot_user,
          { raw: msg },
          skip_validations: true,
          skip_revision: true,
        )
      else
        bot_post =
          PostCreator.create!(
            bot_user,
            topic_id: user_post.topic_id,
            raw: msg,
            skip_validations: true,
            skip_guardian: true,
          )
      end

      bot_post.custom_fields["depiedencap_ai_citations"] = "t"
      bot_post.save_custom_fields
      bot_post.reload
      land_unavailable_stream!(bot_post)
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations publish_unavailable: #{e.class} #{e.message}")
    end

    # Discourse AI a déjà envoyé done:true avec le reply_error TCP.
    # On republie le cooked humoristique pour arrêter le point clignotant.
    def land_unavailable_stream!(bot_post)
      return if bot_post.blank? || !bot_post.topic&.private_message?

      topic = bot_post.topic
      @published_final_update = false
      publish_final_update(
        bot_post,
        user_ids: topic.allowed_users.pluck(:id),
        group_ids: topic.allowed_groups.pluck(:id),
      )
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations land_unavailable_stream: #{e.class} #{e.message}")
    end

    def apply_sanitize!(user_post)
      guide_id = DepiedencapAiCitations::Sanitizer.guide_user_id
      return if guide_id.blank?

      bot_post = user_post.topic.posts.where(user_id: guide_id).order(post_number: :desc).first
      return if bot_post.blank?

      bot_post.reload
      # Le revise Playground a le texte COMPLET ; le stream (0,5 s) peut être en retard.
      full = Thread.current[:dpec_ai_raw_full].presence || @dpec_full_reply
      bot_post.raw = full if full.present?

      if DepiedencapAiCitations::Sanitizer.unavailable_reply?(bot_post.raw)
        DepiedencapAiCitations::Sanitizer.keep_unavailable_only!(bot_post)
        land_unavailable_stream!(bot_post.reload)
        return
      end

      bot_post.custom_fields.delete("depiedencap_ai_citations")
      bot_post.save_custom_fields
      DepiedencapAiCitations::Sanitizer.sanitize!(bot_post)
    rescue StandardError => e
      Rails.logger.warn("DepiedencapAiCitations apply_sanitize: #{e.class} #{e.message}")
    end

    def strip_stream_for?(reply_post)
      return false unless SiteSetting.depiedencap_ai_citations_enabled
      DepiedencapAiCitations::Sanitizer.guide_bot_post?(reply_post) &&
        reply_post.topic&.private_message?
    end

    def stabilize?(post)
      return false unless SiteSetting.depiedencap_ai_citations_enabled
      return false if post.blank? || !post.topic&.private_message?
      return false if post.user_id.to_i <= 0

      guide_id = DepiedencapAiCitations::Sanitizer.guide_user_id
      guide_id.present? && post.topic.topic_allowed_users.exists?(user_id: guide_id)
    end
  end
end
