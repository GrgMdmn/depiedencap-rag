# frozen_string_literal: true

module Jobs
  class DepiedencapSanitizeAiCitations < ::Jobs::Base
    def execute(args)
      post = Post.find_by(id: args[:post_id])
      DepiedencapAiCitations::Sanitizer.sanitize!(post) if post
    end
  end
end
