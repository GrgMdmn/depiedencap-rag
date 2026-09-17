# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module DepiedencapAiCitations
  # Relais VPS → sidecar warmup-proxy (Tailscale). Le navigateur n'atteint pas le mini PC.
  #
  # Ne pas traiter un timeout Tailscale comme une maintenance : le premier SYN
  # après idle dépasse souvent 300 ms, et un cache « indispo » court-circuite
  # le LLM avant le vrai cold start (~40 s + carte d'étapes).
  class WarmupStatus
    CACHE_KEY = "depiedencap_ai_warmup_status"
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 8
    ATTEMPTS = 2

    CONFIRMED_DOWN = [
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      Errno::ENETUNREACH,
    ].freeze

    TRANSIENT = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ETIMEDOUT,
    ].freeze

    def self.unavailable?(status = nil)
      payload = status || fetch
      return false unless payload.is_a?(Hash)
      return false if payload["in_progress"]
      return false if payload["probe_failed"]
      !!(payload["unavailable"] || payload["maintenance_mode"])
    rescue StandardError
      # Inconnu : laisser Faraday parler au LLM plutôt que d'afficher « Oups ».
      false
    end

    def self.fetch(use_cache: true)
      if use_cache
        cached = Rails.cache.read(CACHE_KEY)
        return cached if cached.is_a?(Hash)
      end

      payload = fetch_uncached
      ttl = cache_ttl(payload)
      Rails.cache.write(CACHE_KEY, payload, expires_in: ttl)
      payload
    end

    def self.cache_ttl(payload)
      return 2.seconds if payload["in_progress"]
      return 1.second if payload["probe_failed"]
      return 5.seconds if payload["unavailable"] || payload["maintenance_mode"]
      2.seconds
    end
    private_class_method :cache_ttl

    def self.fetch_uncached
      url = status_url
      return down("missing_url") if url.blank?

      last_error = nil
      ATTEMPTS.times do |attempt|
        begin
          return get_json(url)
        rescue *CONFIRMED_DOWN => e
          Rails.logger.warn("DepiedencapAi warmup-status: #{e.class} #{e.message}")
          return down(e.class.to_s)
        rescue *TRANSIENT => e
          last_error = e
          Rails.logger.warn(
            "DepiedencapAi warmup-status: #{e.class} attempt=#{attempt + 1}/#{ATTEMPTS}",
          )
        rescue StandardError => e
          Rails.logger.warn("DepiedencapAi warmup-status: #{e.class} #{e.message}")
          return probe_failed(e.class.to_s)
        end
      end
      probe_failed(last_error&.class.to_s || "timeout")
    end
    private_class_method :fetch_uncached

    def self.get_json(url)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Get.new(uri.request_uri)
      req["Connection"] = "close"
      resp = http.request(req)
      return probe_failed("upstream_#{resp.code}") unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end
    private_class_method :get_json

    def self.status_url
      llm =
        begin
          LlmModel.order(:id).first
        rescue StandardError
          nil
        end
      return nil if llm.blank? || llm.url.blank?

      base = llm.url.to_s.sub(%r{/v1/.*\z}, "").sub(%r{/+\z}, "")
      "#{base}/warmup-status"
    end

    def self.down(reason = nil)
      payload = {
        "ok" => false,
        "in_progress" => false,
        "phase" => "unavailable",
        "unavailable" => true,
        "maintenance_mode" => false,
        "probe_failed" => false,
        "message" => Unavailable::MESSAGE,
        "maintenance_message" => Unavailable::MESSAGE,
        "hint" => "",
      }
      payload["error"] = reason if reason
      payload
    end
    private_class_method :down

    def self.probe_failed(reason = nil)
      payload = {
        "ok" => false,
        "in_progress" => false,
        "phase" => "probe_failed",
        "unavailable" => false,
        "maintenance_mode" => false,
        "probe_failed" => true,
        "message" => "",
        "hint" => "",
        "steps" => [],
      }
      payload["error"] = reason if reason
      payload
    end
    private_class_method :probe_failed
  end
end
