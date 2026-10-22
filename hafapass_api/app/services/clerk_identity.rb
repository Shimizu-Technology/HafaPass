# frozen_string_literal: true

require "net/http"
require "json"

# Contact information submitted to /users/sync is never identity evidence.
# Read verified ownership directly from Clerk at each recipient acceptance.
class ClerkIdentity
  class LookupUnavailable < StandardError; end

  DEFAULT_TIMEOUT = 5
  # Account creation waits on the lookup while the user signs in.
  SIGN_IN_TIMEOUT = 1.5

  class RequestCache < ActiveSupport::CurrentAttributes
    attribute :verified_emails, :profiles
  end

  class << self
    def with_request_cache(&block)
      RequestCache.set(verified_emails: {}, profiles: {}, &block)
    end

    def verified_email_addresses(clerk_id, require_available: false)
      cache = RequestCache.verified_emails
      # Cache only within this request, including failures. The next acceptance
      # request rechecks the provider, so revoked addresses cannot linger.
      addresses = if cache
        cache.fetch(clerk_id) { cache[clerk_id] = fetch_verified_email_addresses(clerk_id)&.freeze }
      else
        fetch_verified_email_addresses(clerk_id)
      end
      raise LookupUnavailable, "Verified identity lookup is unavailable" if require_available && addresses.nil?

      addresses || []
    end

    # Display/contact data only. Never use persisted profile fields as proof of
    # email ownership or authorization; those checks still refetch each request.
    # A cached failure only answers lookups that would wait no longer, so a
    # short sign-in lookup that timed out never blocks a later full-length one.
    def profile(clerk_id, timeout: DEFAULT_TIMEOUT)
      cache = RequestCache.profiles
      return fetch_profile(clerk_id, timeout) unless cache

      entry = cache[clerk_id]
      return entry[:profile] if entry && (entry[:profile] || entry[:timeout] >= timeout)

      cache[clerk_id] = { profile: fetch_profile(clerk_id, timeout), timeout: timeout }
      cache[clerk_id][:profile]
    end

    def email_matches?(user:, email:)
      target = email.to_s.strip.downcase
      target.present? && verified_email_addresses(user.clerk_id).include?(target)
    end

    # Idempotent provider cleanup. A missing credential or provider failure is
    # reported to the admin queue for manual completion.
    def delete_user(clerk_id)
      return false if clerk_id.blank? || ENV["CLERK_SECRET_KEY"].blank?

      uri = URI("https://api.clerk.com/v1/users/#{ERB::Util.url_encode(clerk_id)}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: DEFAULT_TIMEOUT, read_timeout: DEFAULT_TIMEOUT) do |http|
        request = Net::HTTP::Delete.new(uri)
        request["Authorization"] = "Bearer #{ENV.fetch('CLERK_SECRET_KEY')}"
        http.request(request)
      end
      response.code == "200" || response.code == "204" || response.code == "404"
    rescue StandardError => error
      Rails.logger.warn("Clerk deletion unavailable (#{error.class})")
      false
    end

    private

    def fetch_verified_email_addresses(clerk_id)
      profile(clerk_id)&.fetch(:verified_emails)
    end

    def fetch_profile(clerk_id, timeout)
      return nil if clerk_id.blank? || ENV["CLERK_SECRET_KEY"].blank?

      uri = URI("https://api.clerk.com/v1/users/#{ERB::Util.url_encode(clerk_id)}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: timeout, read_timeout: timeout) do |http|
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{ENV.fetch('CLERK_SECRET_KEY')}"
        http.request(request)
      end
      return nil unless response.code == "200"

      user = JSON.parse(response.body)
      return nil unless user["id"] == clerk_id && user["email_addresses"].is_a?(Array)

      return nil unless user["email_addresses"].all? { |address| address.is_a?(Hash) }
      verified_addresses = user["email_addresses"].select do |address|
        address["verification"].is_a?(Hash) && address.dig("verification", "status") == "verified"
      end
      return nil unless verified_addresses.all? { |address| address["email_address"].is_a?(String) }
      emails = verified_addresses.filter_map { |address| address["email_address"].strip.downcase.presence }.uniq.freeze
      primary = verified_addresses.find { |address| address["id"] == user["primary_email_address_id"] }
      {
        verified_emails: emails,
        email: primary&.fetch("email_address", nil)&.strip&.downcase.presence || emails.first,
        first_name: user["first_name"].is_a?(String) ? user["first_name"].strip.presence : nil,
        last_name: user["last_name"].is_a?(String) ? user["last_name"].strip.presence : nil
      }.freeze
    rescue StandardError => error
      Rails.logger.warn("Clerk identity verification unavailable (#{error.class})")
      nil
    end
  end
end
