# frozen_string_literal: true

class DataRetention
  CONFIG = Rails.root.join("config/data_retention.yml")
  BATCH_SIZE = 100
  # Only abandoned checkout artifacts may be removed with an order. New foreign
  # key children are blockers until explicitly reviewed here.
  PENDING_ORDER_CHILDREN = %w[seat_holds catalog_item_holds inventory_holds seat_hold_sessions
    order_items promo_redemptions referral_attributions acquisition_attributions marketplace_funnel_events].freeze

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

    !SiteSetting.first&.retention_purge_enabled?
  end

  def self.anonymize_order!(order, eligible_ticket_ids: nil, eligible_support_note_ids: nil,
    anonymize_responses: nil)
    # Keep amounts, references and status so finance and tax reporting still reconcile.
    # Use a stable synthetic address to make retries idempotent.
    replacement = "deleted+order-#{order.id}@privacy.invalid"
    ticket_ids = eligible_ticket_ids || order.tickets.where(holder_user_id: [nil, order.user_id])
      .where("holder_email IS NULL OR lower(holder_email) = ?", order.buyer_email.to_s.downcase).pluck(:id)
    anonymize_responses = order.tickets.count == ticket_ids.length if anonymize_responses.nil?
    Ticket.where(id: ticket_ids).update_all(attendee_email: nil, attendee_name: nil, holder_email: nil, holder_user_id: nil,
      qr_code: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    if anonymize_responses
      RegistrationResponse.where(order_id: order.id).update_all(answer: {}, retention_anonymized_at: Time.current,
        updated_at: Time.current)
    end
    TicketTransfer.where(ticket_id: ticket_ids).update_all(recipient_email: replacement,
      recipient_name: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    deliveries = MessageDelivery.where(order_id: order.id, ticket_id: [nil, *ticket_ids])
      .or(MessageDelivery.where(ticket_id: ticket_ids))
    MessageProviderEvent.where(message_delivery_id: deliveries.select(:id)).update_all(payload: {},
      processing_error: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    deliveries.where(status: [:queued, :delayed, :failed]).update_all(status: MessageDelivery.statuses.fetch("cancelled"))
    deliveries.update_all(recipient: replacement, metadata: {},
      outbound_payload: {}, outbound_wire_body: nil, wire_body_digest: nil, last_error: nil,
      retention_anonymized_at: Time.current, updated_at: Time.current)
    Payment.where(order_id: order.id).update_all(provider_payload: {}, failure_message: nil, updated_at: Time.current)
    Refund.where(order_id: order.id).update_all(provider_payload: {}, reason: nil, failure_message: nil, updated_at: Time.current)
    Dispute.where(order_id: order.id).update_all(provider_payload: {}, updated_at: Time.current)
    PaymentEvent.where(payment_id: order.payments.select(:id)).update_all(data: {}, updated_at: Time.current)
    WebhookEvent.where(id: PaymentEvent.where(payment_id: order.payments.select(:id)).select(:webhook_event_id))
      .update_all(payload: {}, last_error: nil, updated_at: Time.current)
    FeeComponent.where(order_id: order.id).update_all(metadata: {}, updated_at: Time.current)
    CardPresentPaymentAttempt.where(order_id: order.id).update_all(provider_response: {}, failure_message: nil,
      updated_at: Time.current)
    ReconciliationException.where(order_id: order.id).update_all(details: {}, updated_at: Time.current)
    notes = if eligible_support_note_ids
      SupportNote.where(id: eligible_support_note_ids)
    else
      SupportNote.where(order_id: order.id, ticket_id: [nil, *ticket_ids])
        .or(SupportNote.where(ticket_id: ticket_ids))
    end
    notes.update_all(body: "[redacted]", retention_anonymized_at: Time.current, updated_at: Time.current)
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
      refund_reason: nil,
      marketing_opt_in: false, user_id: nil, guest_access_revoked_at: Time.current,
      retention_anonymized_at: Time.current, updated_at: Time.current)
  end

  def self.unresolved_money?(order)
    order.disputes.open.exists? || order.refunds.pending.exists? ||
      order.event.payouts.where(status: Payout.statuses.slice("pending", "processing", "held").values).exists?
  end

  def self.held?(record)
    return LegalHold.for_order?(record) if record.is_a?(Order)
    return LegalHold.for_user?(record) if record.is_a?(User)
    if record.is_a?(Organization)
      return LegalHold.active.exists?(scope_type: "organization", scope_value: record.id.to_s)
    end
    if record.is_a?(Event)
      return LegalHold.active.where(scope_type: "event", scope_value: record.id.to_s)
        .or(LegalHold.active.where(scope_type: "organization", scope_value: record.organization_id.to_s)).exists?
    end

    scopes = []
    scopes << ["organization", record.organization_id.to_s] if record.respond_to?(:organization_id) && record.organization_id
    scopes << ["event", record.event_id.to_s] if record.respond_to?(:event_id) && record.event_id
    scopes << ["order", record.order_id.to_s] if record.respond_to?(:order_id) && record.order_id
    scopes << ["user", record.user_id.to_s] if record.respond_to?(:user_id) && record.user_id
    scopes << ["user", record.actor_user_id.to_s] if record.respond_to?(:actor_user_id) && record.actor_user_id
    scopes << ["user", record.requested_by_id.to_s] if record.respond_to?(:requested_by_id) && record.requested_by_id
    scopes << ["user", record.holder_user_id.to_s] if record.respond_to?(:holder_user_id) && record.holder_user_id
    %i[email buyer_email requester_email recipient recipient_email holder_email].each do |field|
      scopes << ["buyer_email", record.public_send(field).to_s.downcase] if
        record.respond_to?(field) && record.public_send(field).present?
    end
    return true if scopes.any? { |type, value| LegalHold.active.exists?(scope_type: type, scope_value: value) }

    return held?(record.event) if record.is_a?(OrganizerSalesExportRequest)
    if record.is_a?(AuditLog)
      subject = case record.auditable_type
      when "Order" then Order.find_by(id: record.auditable_id)
      when "Event" then Event.find_by(id: record.auditable_id)
      when "Organization" then Organization.find_by(id: record.auditable_id)
      end
      return held?(subject) if subject
    end
    related = record.order if record.respond_to?(:order)
    related ||= record.ticket&.order if record.respond_to?(:ticket)
    related ||= record.payment&.order if record.respond_to?(:payment)
    related ||= record.payment_event&.payment&.order if record.respond_to?(:payment_event)
    if record.respond_to?(:message_delivery) && record.message_delivery
      return true if held?(record.message_delivery)
    end
    return true if related && LegalHold.for_order?(related)

    event = record.event if record.respond_to?(:event)
    event ||= record.ticket&.event if record.respond_to?(:ticket)
    event && LegalHold.active.where(scope_type: "organization", scope_value: event.organization_id.to_s)
      .or(LegalHold.active.where(scope_type: "event", scope_value: event.id.to_s)).exists?
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

  def self.pending_order_purgeable?(order)
    return false unless order.pending? || order.expired?
    return false if held?(order)
    return false if order.payments.exists? || order.refunds.exists? || order.disputes.exists? ||
      order.tickets.exists? || PrivacyRequest.where(order_id: order.id).exists? ||
      AuditLog.where(auditable_type: "Order", auditable_id: order.id).exists? ||
      CardPresentPaymentAttempt.where(order_id: order.id).exists? ||
      LiveMoneyProofAuthorization.where(order_id: order.id).exists? ||
      FeeComponent.where(order_id: order.id).exists? ||
      MessageDelivery.where(order_id: order.id).exists?
    # CheckoutAttempt is a permanent retry tombstone. A still-active lease may
    # have no order_id yet, so also fence the digest carried by the order.
    return false if CheckoutAttempt.where(order_id: order.id).exists?
    return false if order.checkout_key_digest.present? &&
      CheckoutAttempt.where(checkout_key_digest: order.checkout_key_digest).exists?
    return false if PaymentEvent.joins(:payment).where(payments: { order_id: order.id }).exists?
    return false if WebhookEvent.where("payload::text LIKE ? OR payload::text LIKE ?",
      "%#{order.reference}%", "%#{order.id}%").exists?
    return false if MessageProviderEvent.joins(:message_delivery)
      .where(message_deliveries: { order_id: order.id }).exists?
    return false if MessageProviderEvent.where("payload::text LIKE ? OR payload::text LIKE ?",
      "%#{order.reference}%", "%#{order.id}%").exists?

    connection = ActiveRecord::Base.connection
    connection.data_sources.each do |table|
      next if %w[schema_migrations ar_internal_metadata].include?(table)

      connection.foreign_keys(table).select { |key| key.to_table == "orders" }.each do |key|
        next if PENDING_ORDER_CHILDREN.include?(table)

        return false if connection.select_value(<<~SQL.squish)
          SELECT 1 FROM #{connection.quote_table_name(table)}
          WHERE #{connection.quote_column_name(key.column)} = #{connection.quote(order.id)} LIMIT 1
        SQL
      end
    end
    true
  end

  def self.delete_pending_order!(order)
    Order.transaction do
      order.lock!
      return false unless pending_order_purgeable?(order)

      item_ids = OrderItem.where(order_id: order.id).select(:id)
      SeatHold.where(order_item_id: item_ids).delete_all
      CatalogItemHold.where(order_item_id: item_ids).delete_all
      InventoryHold.where(order_id: order.id).delete_all
      SeatHoldSession.where(order_id: order.id).delete_all
      PromoRedemption.where(order_id: order.id).delete_all
      ReferralAttribution.where(order_id: order.id).delete_all
      AcquisitionAttribution.where(order_id: order.id).delete_all
      MarketplaceFunnelEvent.where(order_id: order.id).delete_all
      OrderItem.where(order_id: order.id).delete_all
      order.delete
      true
    end
  end
end
