# frozen_string_literal: true

require "uri"

module LiveMoneyProofAuthorizations
  class Manager
    class AuthorizationError < StandardError; end

    def self.request!(event:, buyer_email:, max_amount_cents:, actor:, expires_at:, request: nil)
      authorization = nil
      event.with_lock do
        email = buyer_email.to_s.strip.downcase
        unless email.match?(URI::MailTo::EMAIL_REGEXP)
          raise AuthorizationError, "A valid proof buyer email is required"
        end
        validate_candidate!(event)
        account = event.organization.payout_account
        raise AuthorizationError, "A current payout-ready connected account is required" unless account
        unless LiveMoneyProof.provider_ready?(account)
          raise AuthorizationError, "Live Stripe and payout capabilities must be configured and independently approved"
        end
        rehearsal = EventDayRehearsal.active_approval(event)
        raise AuthorizationError, "A current Gate G rehearsal approval is required" unless rehearsal
        if open_authorization(event)
          raise AuthorizationError, "Revoke, expire, or consume the current proof authorization first"
        end
        expiry = parse_time(expires_at)
        unless expiry && expiry > Time.current && expiry <= 2.hours.from_now
          raise AuthorizationError, "Proof authorization must expire within the next two hours"
        end
        amount = Integer(max_amount_cents, exception: false)
        unless amount&.between?(1, LiveMoneyProofAuthorization::MAX_AMOUNT_CENTS)
          raise AuthorizationError, "Proof authorization amount must be between 1 and 500 cents"
        end
        unless actor&.admin?
          raise AuthorizationError, "An administrator must request the proof authorization"
        end

        authorization = event.live_money_proof_authorizations.create!(
          connected_account: account, event_day_rehearsal_review: rehearsal, requested_by_user: actor,
          buyer_email_digest: LiveMoneyProofAuthorization.email_digest(email), max_amount_cents: amount,
          event_state_digest: PilotReadiness.event_state_digest(event),
          application_revision: PilotReadiness.application_revision,
          provider_state_digest: account.readiness_state_digest,
          platform_configuration_digest: LiveMoneyProof.platform_configuration_digest,
          expires_at: expiry
        )
        record!(authorization, "live_money_proof.authorization_requested", actor, request)
      end
      authorization
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise AuthorizationError, error_message(e)
    end

    def self.approve!(authorization:, actor:, request: nil)
      authorization.with_lock do
        raise AuthorizationError, "Only an administrator can approve a proof authorization" unless actor&.admin?
        raise AuthorizationError, "The requester cannot approve their own proof authorization" if
          authorization.requested_by_user_id == actor.id
        raise AuthorizationError, "This proof authorization is already approved" if authorization.approved?
        raise AuthorizationError, "This proof authorization is expired, revoked, or consumed" if
          authorization.expires_at <= Time.current || authorization.revoked? || authorization.consumed?
        unless authorization.current_bindings?
          raise AuthorizationError, "Event, Gate G, provider, account, or application state changed; request a new authorization"
        end

        authorization.update!(approved_by_user: actor, approved_at: Time.current)
        record!(authorization, "live_money_proof.authorization_approved", actor, request)
      end
      authorization
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise AuthorizationError, error_message(e)
    end

    def self.revoke!(authorization:, actor:, reason:, request: nil)
      raise AuthorizationError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      raise AuthorizationError, "Only an administrator can revoke a proof authorization" unless actor&.admin?
      authorization.with_lock do
        raise AuthorizationError, "Consumed proof authorizations cannot be revoked" if authorization.consumed?
        raise AuthorizationError, "This proof authorization is already revoked" if authorization.revoked?
        authorization.update!(revoked_at: Time.current, revocation_reason: reason.to_s.strip)
        record!(authorization, "live_money_proof.authorization_revoked", actor, request)
      end
      authorization
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise AuthorizationError, error_message(e)
    end

    def self.find_available(event:, user:, buyer_email:)
      digest = LiveMoneyProofAuthorization.email_digest(buyer_email)
      event.live_money_proof_authorizations.where(buyer_email_digest: digest, order_id: nil, revoked_at: nil)
        .where.not(approved_at: nil).where("expires_at > ?", Time.current).order(created_at: :desc)
        .detect { |authorization| authorization.available_for?(user: user, buyer_email: buyer_email) }
    end

    def self.claim!(authorization:, order:, amount_cents:, user:, buyer_email:, request: nil)
      authorization.with_lock do
        unless authorization.available_for?(user: user, buyer_email: buyer_email)
          raise AuthorizationError, "The live-money proof authorization is unavailable or stale"
        end
        unless order.event_id == authorization.event_id && amount_cents.to_i.between?(1, authorization.max_amount_cents)
          raise AuthorizationError, "The live-money proof order exceeds its authorized scope"
        end

        authorization.update!(order: order, consumed_at: Time.current)
        record!(authorization, "live_money_proof.authorization_consumed", user, request)
      end
      authorization
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise AuthorizationError, error_message(e)
    end

    def self.open_authorization(event)
      event.live_money_proof_authorizations.where(order_id: nil, revoked_at: nil)
        .where("expires_at > ?", Time.current).order(created_at: :desc).first
    end
    private_class_method :open_authorization

    def self.validate_candidate!(event)
      raise AuthorizationError, "The proof event must be published" unless event.published?
      unless event.live_money_proof_candidate? && event.live_money_proof_candidate_configured?
        raise AuthorizationError, "Use a hidden [LIVE MONEY TEST] event with one ticket priced at $5 or less"
      end
      raise AuthorizationError, "The proof event must not already have an order" if event.orders.exists?
    end
    private_class_method :validate_candidate!

    def self.parse_time(value)
      value.respond_to?(:to_time) ? value.to_time : Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
    private_class_method :parse_time

    def self.record!(authorization, action, actor, request)
      AuditLogger.record!(
        action: action, auditable: authorization, actor: actor, organization: authorization.event.organization,
        after_data: authorization.attributes.slice(
          "id", "event_id", "connected_account_id", "event_day_rehearsal_review_id",
          "requested_by_user_id", "approved_by_user_id", "order_id", "max_amount_cents",
          "event_state_digest", "application_revision", "provider_state_digest",
          "platform_configuration_digest", "expires_at", "approved_at", "consumed_at", "revoked_at",
          "revocation_reason"
        ), request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Live-money proof authorization conflicts with existing state"
    end
    private_class_method :error_message
  end
end
