# frozen_string_literal: true

require "net/http"
require "uri"

class CardPresentGateway
  class PaymentError < StandardError; end
  class ResultUnknown < StandardError; end

  Result = Data.define(:provider_payment_id, :amount_cents, :currency, :state, :result, :provider_response)

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 65
  SAFE_RESPONSE_FIELDS = %w[id amount result externalPaymentId offline].freeze

  def self.access_token_environment_key(account)
    "CLOVER_REST_PAY_ACCESS_TOKEN_ORGANIZATION_#{account.organization_id}"
  end

  def self.configured_for?(account)
    return true if Rails.env.development? || Rails.env.test?

    ENV["CLOVER_REST_PAY_BASE_URL"].present? && ENV[access_token_environment_key(account)].present?
  end

  def initialize(http_client: Net::HTTP, simulate: Rails.env.development? || Rails.env.test?)
    @http_client = http_client
    @simulate = simulate
  end

  def charge(account:, amount_cents:, currency:, external_payment_id:, idempotency_key:)
    raise PaymentError, "Card-present account is not payment ready" unless account.payment_ready?
    raise PaymentError, "Clover REST Pay is not configured for this organization" unless self.class.configured_for?(account)
    raise PaymentError, "Clover REST Pay supports USD transactions only" unless currency.to_s.casecmp?("usd")

    return simulated_result(amount_cents, currency, external_payment_id) if simulate

    response = perform_request(
      account: account,
      amount_cents: amount_cents,
      external_payment_id: external_payment_id,
      idempotency_key: idempotency_key
    )
    parse_response(response, amount_cents: amount_cents, currency: currency, external_payment_id: external_payment_id)
  end

  private

  attr_reader :http_client, :simulate

  def endpoint
    base = ENV.fetch("CLOVER_REST_PAY_BASE_URL")
    uri = URI.join("#{base.delete_suffix("/")}/", "v1/payments")
    if !simulate && (uri.scheme != "https" || !(uri.host == "clover.com" || uri.host&.end_with?(".clover.com")))
      raise PaymentError, "Clover REST Pay endpoint is not approved"
    end
    uri
  rescue KeyError, URI::InvalidURIError
    raise PaymentError, "Clover REST Pay is not configured"
  end

  def perform_request(account:, amount_cents:, external_payment_id:, idempotency_key:)
    uri = endpoint
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{ENV.fetch(self.class.access_token_environment_key(account))}"
    request["Content-Type"] = "application/json"
    request["Accept"] = "application/json"
    request["X-Clover-Device-Id"] = account.device_id
    request["X-POS-Id"] = account.pos_id
    request["X-Clover-Timeout"] = "60"
    request["Idempotency-Key"] = idempotency_key
    request["User-Agent"] = "HafaPass/1.0"
    request.body = {
      amount: amount_cents,
      externalPaymentId: external_payment_id,
      final: true,
      capture: true
    }.to_json

    http_client.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT,
      read_timeout: READ_TIMEOUT) { |http| http.request(request) }
  rescue KeyError
    raise PaymentError, "Clover REST Pay is not configured"
  rescue Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError, SocketError, SystemCallError => e
    raise ResultUnknown, "The terminal result could not be confirmed (#{e.class.name})"
  end

  def parse_response(response, amount_cents:, currency:, external_payment_id:)
    parsed = JSON.parse(response.body.presence || "{}")
    payment = parsed["payment"].is_a?(Hash) ? parsed.fetch("payment") : parsed

    code = response.code.to_i
    if [408, 500, 503, 504].include?(code) || code >= 520
      raise ResultUnknown, "The terminal result could not be confirmed"
    end
    unless response.is_a?(Net::HTTPSuccess)
      message = parsed.dig("error", "message") || parsed["message"] || "The terminal declined or cancelled the payment"
      raise PaymentError, message.to_s.first(240)
    end
    raise PaymentError, "The terminal payment was cancelled" if code == 209

    card_transaction = payment["cardTransaction"].is_a?(Hash) ? payment.fetch("cardTransaction") : {}
    exact_match = payment["result"] == "SUCCESS" && payment["amount"].to_i == amount_cents.to_i &&
      payment["externalPaymentId"] == external_payment_id && card_transaction["state"] == "CLOSED" &&
      payment["id"].present?
    raise ResultUnknown, "The terminal response did not exactly match the requested sale" unless exact_match

    Result.new(
      provider_payment_id: payment.fetch("id"),
      amount_cents: payment.fetch("amount").to_i,
      currency: currency.to_s.downcase,
      state: card_transaction.fetch("state"),
      result: payment.fetch("result"),
      provider_response: safe_response(payment, card_transaction)
    )
  rescue JSON::ParserError, KeyError, TypeError
    raise ResultUnknown, "The terminal returned an unreadable payment result"
  end

  def safe_response(payment, card_transaction)
    payment.slice(*SAFE_RESPONSE_FIELDS).merge(
      "state" => card_transaction["state"],
      "cardType" => card_transaction["cardType"],
      "last4" => card_transaction["last4"] || card_transaction["last4Digits"]
    ).compact
  end

  def simulated_result(amount_cents, currency, external_payment_id)
    provider_payment_id = "sim_clover_#{SecureRandom.hex(10)}"
    Result.new(
      provider_payment_id: provider_payment_id,
      amount_cents: amount_cents,
      currency: currency.to_s.downcase,
      state: "CLOSED",
      result: "SUCCESS",
      provider_response: {
        "id" => provider_payment_id,
        "amount" => amount_cents,
        "result" => "SUCCESS",
        "state" => "CLOSED",
        "externalPaymentId" => external_payment_id,
        "cardType" => "SIMULATED",
        "last4" => "0000"
      }
    )
  end
end
