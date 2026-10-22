# frozen_string_literal: true

require "json"
require "jwt"
require "net/http"
require "uri"

module Wallet
  # Minimal Google Wallet REST client authenticated as the issuer's service
  # account (OAuth 2.0 JWT bearer grant).
  class GoogleWalletClient
    class Error < StandardError; end
    # Worth retrying: throttling, provider errors and network failures.
    class RetryableError < Error; end

    TOKEN_URL = "https://oauth2.googleapis.com/token"
    API_BASE = "https://walletobjects.googleapis.com/walletobjects/v1"
    SCOPE = "https://www.googleapis.com/auth/wallet_object.issuer"
    TIMEOUT = 15
    NETWORK_ERRORS = [Timeout::Error, IOError, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse].freeze

    Response = Struct.new(:status, :body, keyword_init: true)

    @token_mutex = Mutex.new

    class << self
      attr_reader :token_mutex

      def access_token
        token_mutex.synchronize do
          if @access_token.nil? || @access_token_expires_at <= 60.seconds.from_now
            @access_token, @access_token_expires_at = fetch_access_token
          end
          @access_token
        end
      end

      def reset_access_token!
        token_mutex.synchronize { @access_token = nil }
      end

      private

      def fetch_access_token
        now = Time.current.to_i
        assertion = JWT.encode({ iss: ENV.fetch("GOOGLE_WALLET_SERVICE_ACCOUNT_EMAIL"), scope: SCOPE, aud: TOKEN_URL,
          iat: now, exp: now + 3600 }, GoogleSaveLink.private_key, "RS256")
        response = request(Net::HTTP::Post, TOKEN_URL, form: {
          grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: assertion
        })
        raise_for(response, "token")
        body = JSON.parse(response.body)
        [body.fetch("access_token"), Time.current + body.fetch("expires_in", 3600).to_i.seconds]
      rescue JSON::ParserError, KeyError
        raise RetryableError, "Google OAuth returned an unreadable token response"
      end

      public

      def request(klass, url, json: nil, form: nil, token: nil)
        uri = URI.parse(url)
        request = klass.new(uri)
        request["Authorization"] = "Bearer #{token}" if token
        if json
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(json)
        elsif form
          request.set_form_data(form)
        end
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = TIMEOUT
        http.read_timeout = TIMEOUT
        response = http.start { |connection| connection.request(request) }
        Response.new(status: response.code.to_i, body: response.body.to_s)
      rescue *NETWORK_ERRORS => e
        raise RetryableError, "Google Wallet request failed: #{e.class}"
      end

      def raise_for(response, action)
        return if response.status.between?(200, 299)
        raise RetryableError, "Google Wallet #{action} returned #{response.status}" if response.status == 429 || response.status >= 500

        raise Error, "Google Wallet #{action} returned #{response.status}"
      end
    end

    def update_object(object)
      call(Net::HTTP::Put, "#{API_BASE}/eventTicketObject/#{escape(object.fetch(:id))}", object)
    end

    def insert_object(object)
      call(Net::HTTP::Post, "#{API_BASE}/eventTicketObject", object)
    end

    # Google expects updates to an approved class to go back for review.
    def update_class(event_class)
      call(Net::HTTP::Put, "#{API_BASE}/eventTicketClass/#{escape(event_class.fetch(:id))}",
        event_class.merge(reviewStatus: "UNDER_REVIEW"))
    end

    def insert_class(event_class)
      call(Net::HTTP::Post, "#{API_BASE}/eventTicketClass", event_class)
    end

    private

    def call(klass, url, body)
      response = self.class.request(klass, url, json: body, token: self.class.access_token)
      if response.status == 401
        self.class.reset_access_token!
        response = self.class.request(klass, url, json: body, token: self.class.access_token)
      end
      response
    end

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end
  end
end
