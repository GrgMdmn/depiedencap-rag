# frozen_string_literal: true

module DepiedencapAiCitations
  # Purge MP du compte partagé **demo uniquement**.
  # Jamais un autre membre : username figé, refus staff, MP sans autre humain.
  class DemoPurge
    # Figé volontairement — pas de SiteSetting (un admin pourrait viser un autre compte).
    USERNAME = "demo"

    def self.demo_user?(user)
      return false if user.blank?
      return false if user.id.to_i <= 0
      return false unless user.username_lower == USERNAME
      return false if user.staff? || user.admin? || user.moderator?

      true
    end

    def self.wipe!(user)
      return 0 unless SiteSetting.depiedencap_ai_citations_enabled
      return 0 unless demo_user?(user)

      locked = User.find_by(username_lower: USERNAME)
      return 0 if locked.blank? || locked.id != user.id
      return 0 if locked.staff? || locked.admin? || locked.moderator?

      topic_ids =
        Topic
          .joins(:topic_allowed_users)
          .where(archetype: Archetype.private_message)
          .where(topic_allowed_users: { user_id: locked.id })
          .distinct
          .pluck(:id)

      deleted = 0
      topic_ids.each do |tid|
        topic = Topic.with_deleted.find_by(id: tid)
        next if topic.nil? || topic.deleted_at.present?
        next unless topic.private_message?

        human_ids =
          TopicAllowedUser.where(topic_id: tid).where("user_id > 0").pluck(:user_id).uniq
        next unless human_ids == [locked.id]

        first = topic.first_post || topic.posts.with_deleted.order(:post_number).first
        next if first.nil?

        PostDestroyer.new(
          Discourse.system_user,
          first,
          context: "depiedencap demo purge",
          force_destroy: true,
        ).destroy
        deleted += 1
      rescue StandardError => e
        Rails.logger.warn(
          "DepiedencapAiCitations::DemoPurge topic=#{tid}: #{e.class} #{e.message}",
        )
      end
      deleted
    end
  end
end
