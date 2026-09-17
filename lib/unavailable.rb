# frozen_string_literal: true

module DepiedencapAiCitations
  # Même texte que le sidecar warmup-proxy (MAINTENANCE_MESSAGE).
  # Pod éteint (timeout) et mode maintenance (HTTP 200 intercepté) → ce message,
  # sans footer Sources / CTA.
  class Unavailable
    MESSAGE = <<~MSG.strip.freeze
      🔧 Oups, on dirait que l'administrateur est en train de travailler très très fort sur le serveur... 🛠️

      Le chatbot est donc indisponible pour le moment 🤭

      N'hésitez pas à réessayer plus tard ! ⏳
    MSG

    FINGERPRINT = "Oups, on dirait que l'administrateur"

    # Réponses « le LLM n'a pas généré » : sidecar, fallback Discourse AI, timeouts.
    ERROR_FINGERPRINTS = [
      FINGERPRINT,
      "Le chatbot est donc indisponible",
      "problème inattendu en essayant de répondre",
      "Détails de l'erreur",
      "Détails de l’erreur",
      "Failed to open TCP",
      "final-destination.invalid",
      "couldn't generate a response",
      "could not generate a response",
      "couldn't generate a reply",
      "encountered an error while generating",
      "unexpected issue while trying to reply",
      "n'ai pas pu générer",
      "n’ai pas pu générer",
      "impossible de générer une réponse",
      "having trouble generating a response",
      "trouble generating a response",
    ].freeze

    def self.reply?(raw)
      text = raw.to_s
      return false if text.blank?

      ERROR_FINGERPRINTS.any? { |fp| text.include?(fp) }
    end

    def self.connection_error?(error)
      return false if error.blank?

      msg = error.message.to_s
      error.is_a?(Errno::ECONNREFUSED) ||
        error.is_a?(Errno::EHOSTUNREACH) ||
        error.is_a?(Errno::ENETUNREACH) ||
        error.is_a?(Net::OpenTimeout) ||
        error.is_a?(Net::ReadTimeout) ||
        error.is_a?(SocketError) ||
        faraday_connection_error?(error) ||
        msg.match?(
          /
            connection\ refused|
            Failed\ to\ open\ TCP|
            timed?\s*out|
            timeout|
            execution\ expired|
            Name\ or\ service\ not\ known|
            No\ route\ to\ host|
            Connection\ reset|
            Faraday::ConnectionFailed|
            Net::OpenTimeout|
            Net::ReadTimeout
          /ix,
        )
    end

    def self.faraday_connection_error?(error)
      return false unless defined?(Faraday)

      error.is_a?(Faraday::ConnectionFailed) ||
        error.is_a?(Faraday::TimeoutError) ||
        (defined?(Faraday::SSLError) && error.is_a?(Faraday::SSLError))
    end
    private_class_method :faraday_connection_error?
  end
end
