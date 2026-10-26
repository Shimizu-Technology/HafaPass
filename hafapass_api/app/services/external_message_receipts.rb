# frozen_string_literal: true

# An append-only decision, not receipt processing. No receipt/delivery mutation
# or enqueue belongs here. The action/subject survive audit payload redaction.
class ExternalMessageReceipts
  class Rejected < StandardError; end
  MANUAL_ACTION = "message_provider_event.external_confirmed"
  SOURCE_ACTION = "message_provider_event.external_source_confirmed"
  ACTIONS = [MANUAL_ACTION, SOURCE_ACTION].freeze
  BENIGN_EVENTS = MessageReceiptProvenance::BENIGN_EVENTS
  IDENTITY_KEYS = %w[id provider provider_event_id provider_message_id event_type].freeze
  MAX_BATCH = 4
  PROOF_REFERENCE = /\A[a-z][a-z0-9_-]{2,39}:[a-z0-9][a-z0-9_\/-]{2,119}\z/

  # Console/operator entry point. Every row needs its exact reviewed identity;
  # caller-supplied IDs alone and stale in-memory admin roles are insufficient.
  def self.call(actor:, receipts:, proof_reference:)
    unless proof_reference.is_a?(String) && proof_reference.match?(PROOF_REFERENCE)
      raise Rejected, "A bounded evidence reference is required"
    end
    unless receipts.is_a?(Array) && receipts.size.between?(1, MAX_BATCH)
      raise Rejected, "Supply one to four exact receipt identities"
    end
    identities = receipts.map do |identity|
      raise Rejected, "Invalid receipt identity" unless identity.is_a?(Hash) && identity.size == IDENTITY_KEYS.size

      identity = identity.stringify_keys
      unless identity.keys.sort == IDENTITY_KEYS.sort && identity["id"].is_a?(Integer) &&
          identity["id"].positive? && (IDENTITY_KEYS - ["id"]).all? { |key| identity[key].is_a?(String) && identity[key].present? }
        raise Rejected, "Invalid receipt identity"
      end
      identity
    end
    raise Rejected, "Duplicate receipt identity" unless identities.pluck("id").uniq.size == identities.size

    MessageProviderEvent.transaction(requires_new: true) do
      current_admin = User.where(id: actor&.id).lock("FOR SHARE NOWAIT").first if actor.is_a?(User) && actor.persisted?
      raise Rejected, "A current platform admin is required" unless current_admin&.admin?

      # Block provider-ID inserts/updates only for this bounded transaction.
      # NOWAIT on all locks avoids waiting on a sender/processor that may hold
      # a receipt before updating its delivery. Busy state aborts the batch;
      # an operator/provider may safely retry the same evidence later.
      lock_deliveries!
      identities.sort_by { |identity| identity.fetch("id") }.map do |identity|
        receipt = MessageProviderEvent.lock("FOR UPDATE NOWAIT").find_by(id: identity.fetch("id"))
        raise Rejected, "Receipt identity changed or is missing" unless receipt && receipt.attributes.slice(*IDENTITY_KEYS) == identity

        validate_unmatched!(receipt)
        record!(receipt, action: MANUAL_ACTION, actor: current_admin, proof_reference: proof_reference)
      end
    end
  end

  # Called ONLY by ResendWebhooksController after raw-byte verification and
  # normal exact-ID processing. Read saved provenance, never replay parameters.
  def self.classify_verified_callback!(receipt)
    return unless receipt.payload.dig("provenance", "application") == "csg_learn"
    return unless eligible?(receipt)

    MessageProviderEvent.transaction(requires_new: true) do
      lock_deliveries!
      receipt.lock!("FOR UPDATE NOWAIT")
      return unless eligible?(receipt)

      record!(receipt, action: SOURCE_ACTION, actor: nil, proof_reference: "signed-application:csg_learn")
    end
  end

  def self.resolved
    decisions = AuditLog.where(action: ACTIONS, auditable_type: "MessageProviderEvent", outcome: "succeeded")
    MessageProviderEvent.where(id: decisions.select(:auditable_id), provider: "resend", event_type: BENIGN_EVENTS,
      message_delivery_id: nil, processed_at: nil, processing_error: [nil, ""])
      .where(<<~SQL.squish)
        NOT EXISTS (SELECT 1 FROM message_deliveries
          WHERE message_deliveries.provider = message_provider_events.provider
          AND message_deliveries.provider_id = message_provider_events.provider_message_id)
      SQL
  end

  def self.lock_deliveries!
    unless MessageDelivery.connection.select_value("SHOW transaction_isolation") == "read committed"
      raise Rejected, "External decisions require a read-committed transaction"
    end
    MessageDelivery.connection.execute("LOCK TABLE message_deliveries IN SHARE MODE NOWAIT")
  end
  private_class_method :lock_deliveries!

  def self.eligible?(receipt)
    receipt.provider == "resend" && receipt.provider_message_id.is_a?(String) && receipt.provider_message_id.present? &&
      BENIGN_EVENTS.include?(receipt.event_type) && receipt.message_delivery_id.nil? && receipt.processed_at.nil? &&
      receipt.processing_error.to_s.empty? &&
      !MessageDelivery.exists?(provider: receipt.provider, provider_id: receipt.provider_message_id)
  end
  private_class_method :eligible?

  def self.validate_unmatched!(receipt)
    raise Rejected, "Receipt is not an unmatched benign external candidate" unless eligible?(receipt)
  end
  private_class_method :validate_unmatched!

  def self.record!(receipt, action:, actor:, proof_reference:)
    identity = receipt.attributes.slice(*IDENTITY_KEYS)
    digest = Digest::SHA256.hexdigest(JSON.generate([identity.sort.to_h, proof_reference]))
    key = "external-receipt/#{receipt.id}/#{digest}"
    existing = AuditLog.where(action: ACTIONS, auditable: receipt).first
    if existing
      unless existing.action == action && existing.deduplication_key == key && existing.outcome == "succeeded"
        raise Rejected, "Receipt already has a different external decision"
      end
      return existing
    end

    # Do not weaken shared AuditLogger policy or inherit a buyer's fail-open
    # context. Explicit actor/source and a mandatory audit are part of success.
    AuditContext.set(fail_open: false, actor: actor, source: actor ? "admin" : "provider") do
      AuditLogger.record!(action: action, auditable: receipt, actor: actor,
        source: actor ? "admin" : "provider", outcome: "succeeded", deduplication_key: key,
        metadata: { proof_reference: proof_reference }) || raise(AuditLogger::WriteError, "External decision requires an audit")
    end
  end
  private_class_method :record!
end
