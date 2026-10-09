# frozen_string_literal: true

require "net/http"
require "json"

# Contact information submitted to /users/sync is never identity evidence.
# Read verified ownership directly from Clerk at each recipient acceptance.
class ClerkIdentity
  class << self
    def verified_email_addresses(clerk_id)
      return [] if clerk_id.blank? || ENV["CLERK_SECRET_KEY"].blank?

      uri = URI("https://api.clerk.com/v1/users/#{ERB::Util.url_encode(clerk_id)}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
        open_timeout: 5, read_timeout: 5) do |http|
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{ENV.fetch('CLERK_SECRET_KEY')}"
        http.request(request)
      end
      return [] unless response.code == "200"

      user = JSON.parse(response.body)
      return [] unless user["id"] == clerk_id

      Array(user["email_addresses"]).filter_map do |address|
        next unless address.dig("verification", "status") == "verified"

        address["email_address"].to_s.strip.downcase.presence
      end.uniq
    rescue StandardError => error
      Rails.logger.warn("Clerk identity verification unavailable (#{error.class})")
      []
    end

    def email_matches?(user:, email:)
      target = email.to_s.strip.downcase
      target.present? && verified_email_addresses(user.clerk_id).include?(target)
    end
  end
end
