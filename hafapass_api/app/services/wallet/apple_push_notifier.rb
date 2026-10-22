# frozen_string_literal: true

require "openssl"

module Wallet
  # Tells devices that a pass changed. Apple Wallet then calls the PassKit web
  # service for the serials and the latest pass. APNs requires HTTP/2 and, for
  # Wallet, authenticates with the Pass Type ID certificate.
  class ApplePushNotifier
    class DeliveryError < StandardError; end

    HOST = "https://api.push.apple.com"
    TIMEOUT = 15.seconds
    # Tokens Apple says will never work again; their registrations are removed.
    GONE_STATUSES = [410].freeze
    GONE_REASONS = %w[BadDeviceToken Unregistered DeviceTokenNotForTopic].freeze

    Result = Struct.new(:status, :reason, keyword_init: true) do
      def delivered?
        status == 200
      end

      def gone?
        GONE_STATUSES.include?(status) || GONE_REASONS.include?(reason)
      end
    end

    class << self
      attr_writer :transport

      def transport
        @transport ||= AsyncTransport.new
      end

      # Returns { push_token => Result }.
      def call(push_tokens)
        tokens = Array(push_tokens).uniq
        return {} if tokens.empty?

        transport.post_all(tokens, topic: ApplePassGenerator.pass_type_identifier)
      end
    end

    class AsyncTransport
      def initialize(host: HOST, ssl_context: nil)
        @host = host
        @ssl_context = ssl_context
      end

      def post_all(tokens, topic:)
        require "async"
        require "async/http/client"
        require "async/http/endpoint"
        require "async/http/protocol/http2"

        results = {}
        Sync do |task|
          client = Async::HTTP::Client.new(endpoint, protocol: Async::HTTP::Protocol::HTTP2)
          task.with_timeout(TIMEOUT.to_i) do
            tokens.each do |token|
              response = client.post("/3/device/#{token}",
                [["apns-topic", topic], ["apns-priority", "5"], ["content-type", "application/json"]], ["{}"])
              body = response.read
              results[token] = Result.new(status: response.status, reason: reason(body))
            end
          end
        ensure
          client&.close
        end
        results
      rescue OpenSSL::PKCS12::PKCS12Error, ArgumentError, KeyError
        raise
      rescue StandardError => e
        # Connection, TLS, HTTP/2 and timeout failures are worth a retry.
        raise DeliveryError, "APNs request failed: #{e.class}"
      end

      private

      def endpoint
        Async::HTTP::Endpoint.parse(@host, ssl_context: @ssl_context || ssl_context, protocol: Async::HTTP::Protocol::HTTP2)
      end

      def ssl_context
        credentials = ApplePassCertificate.load
        OpenSSL::SSL::SSLContext.new.tap do |context|
          context.alpn_protocols = ["h2"]
          context.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
          context.cert = credentials.certificate
          context.key = credentials.key
        end
      end

      def reason(body)
        return if body.blank?

        JSON.parse(body)["reason"]
      rescue JSON::ParserError
        nil
      end
    end
  end
end
