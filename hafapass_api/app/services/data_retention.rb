# frozen_string_literal: true

class DataRetention
  CONFIG = Rails.root.join("config/data_retention.yml")
  BATCH_SIZE = 100

  def self.schedule
    @schedule ||= YAML.safe_load_file(CONFIG).fetch("tables")
  end

  def self.cutoff(period, at: Time.current)
    case period
    when "7_years_after_year_end" then Time.zone.local(at.year - 7, 1, 1)
    when "13_months" then at - 13.months
    when "3_years_after_withdrawal" then at - 3.years
    when "2_days" then at - 2.days
    when "90_days" then at - 90.days
    else nil
    end
  end

  def self.dry_run?
    return true if ActiveModel::Type::Boolean.new.cast(ENV["DATA_RETENTION_DRY_RUN"])
    return false unless Rails.env.production?

    !SiteSetting.instance.retention_purge_enabled?
  end

  def self.anonymize_order!(order)
    # Keep amounts, references and status so finance and tax reporting still reconcile.
    # Use a stable synthetic address to make retries idempotent.
    replacement = "deleted+order-#{order.id}@privacy.invalid"
    ticket_ids = order.tickets.pluck(:id)
    order.tickets.update_all(attendee_email: nil, attendee_name: nil, holder_email: nil, holder_user_id: nil,
      qr_code: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    RegistrationResponse.where(order_id: order.id).update_all(answer: {}, retention_anonymized_at: Time.current,
      updated_at: Time.current)
    TicketTransfer.where(ticket_id: ticket_ids).update_all(recipient_email: replacement,
      recipient_name: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    deliveries = MessageDelivery.where(order_id: order.id).or(MessageDelivery.where(ticket_id: ticket_ids))
    MessageProviderEvent.where(message_delivery_id: deliveries.select(:id)).update_all(payload: {},
      processing_error: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    deliveries.update_all(recipient: replacement, metadata: {},
      outbound_payload: {}, outbound_wire_body: nil, wire_body_digest: nil, last_error: nil,
      retention_anonymized_at: Time.current, updated_at: Time.current)
    Payment.where(order_id: order.id).update_all(provider_payload: {}, failure_message: nil, updated_at: Time.current)
    Refund.where(order_id: order.id).update_all(provider_payload: {}, failure_message: nil, updated_at: Time.current)
    Dispute.where(order_id: order.id).update_all(provider_payload: {}, updated_at: Time.current)
    PaymentEvent.where(payment_id: order.payments.select(:id)).update_all(data: {}, updated_at: Time.current)
    WebhookEvent.where(id: PaymentEvent.where(payment_id: order.payments.select(:id)).select(:webhook_event_id))
      .update_all(payload: {}, last_error: nil, updated_at: Time.current)
    FeeComponent.where(order_id: order.id).update_all(metadata: {}, updated_at: Time.current)
    CardPresentPaymentAttempt.where(order_id: order.id).update_all(provider_response: {}, failure_message: nil,
      updated_at: Time.current)
    ReconciliationException.where(order_id: order.id).update_all(details: {}, updated_at: Time.current)
    SupportNote.where(order_id: order.id).update_all(body: "[redacted]", retention_anonymized_at: Time.current,
      updated_at: Time.current)
    GuestListEntry.where(order_id: order.id).update_all(guest_email: nil, guest_name: "[redacted]",
      guest_phone: nil, notes: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    AdmissionAction.where(ticket_id: ticket_ids).update_all(attendee_snapshot: {}, metadata: {},
      retention_anonymized_at: Time.current, updated_at: Time.current)
    AcquisitionAttribution.where(order_id: order.id).update_all(visitor_hash: "[redacted]", campaign: nil,
      source: nil, medium: nil, updated_at: Time.current)
    MarketplaceFunnelEvent.where(order_id: order.id).update_all(visitor_hash: "[redacted]", campaign: nil,
      source: nil, medium: nil, updated_at: Time.current)
    AuditLog.where(auditable_type: "Order", auditable_id: order.id).update_all(ip_address: nil,
      before_data: {}, after_data: {}, metadata: {}, retention_anonymized_at: Time.current,
      updated_at: Time.current)
    order.update_columns(buyer_email: replacement, buyer_name: "Deleted buyer", buyer_phone: nil,
      marketing_opt_in: false, user_id: nil, guest_access_revoked_at: Time.current,
      retention_anonymized_at: Time.current, updated_at: Time.current)
  end

  def self.unresolved_money?(order)
    order.disputes.open.exists? || order.refunds.pending.exists? ||
      order.event.payouts.where(status: Payout.statuses.slice("pending", "processing", "held").values).exists?
  end

  def self.held?(record)
    case record
    when Order then LegalHold.for_order?(record)
    when User then LegalHold.for_user?(record)
    else
      scopes = []
      scopes << ["organization", record.organization_id.to_s] if record.respond_to?(:organization_id) && record.organization_id
      scopes << ["event", record.event_id.to_s] if record.respond_to?(:event_id) && record.event_id
      scopes << ["order", record.order_id.to_s] if record.respond_to?(:order_id) && record.order_id
      scopes << ["user", record.user_id.to_s] if record.respond_to?(:user_id) && record.user_id
      scopes << ["buyer_email", record.email.to_s.downcase] if record.respond_to?(:email) && record.email.present?
      scopes << ["buyer_email", record.buyer_email.to_s.downcase] if record.respond_to?(:buyer_email) && record.buyer_email.present?
      scopes << ["buyer_email", record.requester_email.to_s.downcase] if record.respond_to?(:requester_email) && record.requester_email.present?
      scopes.any? { |type, value| LegalHold.active.exists?(scope_type: type, scope_value: value) } ||
        (record.respond_to?(:order) && record.order && LegalHold.for_order?(record.order)) ||
        (record.respond_to?(:ticket) && record.ticket&.order && LegalHold.for_order?(record.ticket.order)) ||
        (record.respond_to?(:payment) && record.payment&.order && LegalHold.for_order?(record.payment.order)) ||
        (record.respond_to?(:payment_event) && record.payment_event&.payment&.order &&
          LegalHold.for_order?(record.payment_event.payment.order)) ||
        (record.respond_to?(:message_delivery) && record.message_delivery &&
          (record.message_delivery.order || record.message_delivery.ticket&.order) &&
          LegalHold.for_order?(record.message_delivery.order || record.message_delivery.ticket.order))
    end
  end

  def self.anonymize!(record)
    case record
    when Order then anonymize_order!(record)
    when Payout
      record.update_columns(payee_snapshot: {}, tax_information_snapshot: {}, tax_information_tin: "[redacted]",
        retention_anonymized_at: Time.current, updated_at: Time.current)
    when OrganizerTaxInformation
      record.update_columns(tin: "[redacted]", tin_last_four: "XXXX", legal_name: "[redacted]",
        business_name: nil, mailing_address: "[redacted]", signer_name: "[redacted]",
        retention_anonymized_at: Time.current, updated_at: Time.current)
    when AuditLog
      record.update_columns(ip_address: nil, before_data: {}, after_data: {}, metadata: {},
        retention_anonymized_at: Time.current, updated_at: Time.current)
    when MessageDelivery
      record.update_columns(recipient: "deleted@privacy.invalid", outbound_payload: {}, outbound_wire_body: nil,
        wire_body_digest: nil, metadata: {}, last_error: nil, retention_anonymized_at: Time.current,
        updated_at: Time.current)
    else
      fields = schedule.fetch(record.class.table_name).fetch("pii_columns")
      attrs = fields.to_h do |field|
        column = record.class.columns_hash.fetch(field)
        [field, column.type == :jsonb ? {} : (column.null ? nil : "[redacted]")]
      end
      attrs[:retention_anonymized_at] = Time.current if record.has_attribute?(:retention_anonymized_at)
      attrs[:updated_at] = Time.current if record.has_attribute?(:updated_at)
      record.update_columns(attrs) if attrs.any?
    end
  end

  # A pending order has no captured money, tickets in use, or open operational
  # work. Delete its dependent quote/hold rows first; all other orders stay.
  def self.delete_pending_order!(order)
    raise "Order is not an abandoned pending checkout" unless order.pending? || order.expired?
    raise "Order has money or fulfillment" if order.payments.exists? || order.refunds.exists? ||
      order.disputes.exists? || order.tickets.exists? ||
      PrivacyRequest.where(order_id: order.id).exists?

    connection = ActiveRecord::Base.connection
    tables = connection.data_sources - %w[schema_migrations ar_internal_metadata]
    incoming = tables.to_h do |table|
      [table, connection.foreign_keys(table)]
    end
    delete_tree = lambda do |table, ids|
      incoming.each do |child_table, foreign_keys|
        foreign_keys.select { |key| key.to_table == table }.each do |key|
          child = Class.new(ApplicationRecord) { self.table_name = child_table }
          child_ids = child.where(key.column => ids).pluck(:id)
          delete_tree.call(child_table, child_ids) if child_ids.any?
        end
      end
      Class.new(ApplicationRecord) { self.table_name = table }.where(id: ids).delete_all
    end
    AuditLog.where(auditable_type: "Order", auditable_id: order.id).delete_all
    delete_tree.call("orders", [order.id])
  end
end
