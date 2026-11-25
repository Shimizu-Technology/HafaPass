# frozen_string_literal: true

module Api
  module V1
    module Ops
      # GET /api/v1/ops/summary[?date=YYYY-MM-DD|today]
      #
      # A read-only, aggregate-only endpoint for the morning brief agent. It
      # authenticates with a dedicated bearer token, not a Clerk session, so a
      # leaked token can read this one summary and nothing else.
      #
      # - OPS_SUMMARY_TOKEN holds one token, or several comma-separated (so a
      #   new token can be added before the old one is removed). Each must be
      #   at least MIN_TOKEN_LENGTH characters; shorter ones are ignored.
      # - With no valid token configured the endpoint answers 404, as if it
      #   did not exist.
      # - Tokens are compared as SHA-256 digests with secure_compare, against
      #   every configured token, so timing reveals nothing about a match.
      # - Rack::Attack limits it per address (ops-summary/ip).
      # - Every request writes one structured log line (outcome, request id,
      #   date) and never the token. These are the audit trail; the token has
      #   no user to attribute an audit_logs row to.
      class SummariesController < ApplicationController
        MIN_TOKEN_LENGTH = 32

        skip_before_action :authenticate_user!

        def show
          response.headers["Cache-Control"] = "no-store"
          return audited(:not_configured) { render json: { error: "Not found" }, status: :not_found } if tokens.empty?
          return audited(:unauthorized) { render json: { error: "Unauthorized" }, status: :unauthorized } unless authorized?

          begin
            Operations::DailySummary.resolve_date(params[:date])
          rescue ArgumentError => e
            return audited(:bad_request) { render json: { error: e.message }, status: :unprocessable_entity }
          end

          summary = Operations::DailySummary.call(date: params[:date])
          audited(:ok, date: summary[:guam_date]) { render json: summary }
        end

        private

        def tokens
          @tokens ||= ENV["OPS_SUMMARY_TOKEN"].to_s.split(",").map(&:strip).select { |token| token.length >= MIN_TOKEN_LENGTH }
        end

        def authorized?
          supplied = request.authorization.to_s[/\ABearer (\S+)\z/i, 1]
          return false if supplied.blank?

          digest = Digest::SHA256.digest(supplied)
          tokens.map { |token| ActiveSupport::SecurityUtils.secure_compare(Digest::SHA256.digest(token), digest) }.any?
        end

        def audited(outcome, extra = {})
          Rails.logger.info({ event: "ops_summary_read", outcome: outcome, request_id: request.request_id,
            client_ip: ClientIp.from_env(request.env), **extra }.to_json)
          yield
        end
      end
    end
  end
end
