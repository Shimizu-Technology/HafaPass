# frozen_string_literal: true

class DataRetention
  CONFIG = Rails.root.join("config/data_retention.yml")
  BATCH_SIZE = 100
  # Only abandoned checkout artifacts may be removed with an order. New foreign
  # key children are blockers until explicitly reviewed here.
  PENDING_ORDER_CHILDREN = %w[seat_holds catalog_item_holds inventory_holds seat_hold_sessions
    order_items promo_redemptions referral_attributions acquisition_attributions marketplace_funnel_events].freeze
  # Provider references on a legacy order may predate local Payment rows. Audit
  # this list against orders in schema.rb when adding a new checkout provider.
  ORDER_PROVIDER_REFERENCES = %w[stripe_payment_intent_id stripe_refund_id].freeze

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

  def self.reconciliation_audits_for_orders(order_ids)
    ids = Array(order_ids)
    AuditLog.where(auditable_type: "Refund", auditable_id: Refund.where(order_id: ids).select(:id))
      .or(AuditLog.where(auditable_type: "Dispute", auditable_id: Dispute.where(order_id: ids).select(:id)))
      .or(AuditLog.where(auditable_type: "EventCancellationRefundItem",
        auditable_id: EventCancellationRefundItem.where(order_id: ids).select(:id)))
      .or(AuditLog.where(auditable_type: "EventChangeResponse",
        auditable_id: EventChangeResponse.where(order_id: ids).select(:id)))
  end

  def self.reconciliation_digests_for_orders(orders)
    references = Array(orders).map(&:reference)
    scope = MessageDelivery.where(template: "refund_reconciliation_digest")
    return scope.none if references.empty?

    references.map do |reference|
      scope.where("metadata @> ?", { items: [{ order_reference: reference }] }.to_json)
    end.reduce(&:or)
  end

  def self.anonymize_order!(order, eligible_ticket_ids: nil, eligible_support_note_ids: nil,
    anonymize_responses: nil, buyer_owned: true)
    unless buyer_owned
      order.update_columns(user_id: nil, updated_at: Time.current)
      return
    end
    # Keep amounts, references and status so finance and tax reporting still reconcile.
    # Use a stable synthetic address to make retries idempotent.
    replacement = "deleted+order-#{order.id}@privacy.invalid"
    ticket_ids = eligible_ticket_ids || order.tickets.where(holder_user_id: [nil, order.user_id])
      .where("holder_email IS NULL OR lower(holder_email) = ?", order.buyer_email.to_s.downcase).pluck(:id)
    anonymize_responses = order.tickets.count == ticket_ids.length if anonymize_responses.nil?
    update_unheld(Ticket.where(id: ticket_ids), attendee_email: nil, attendee_name: nil, holder_email: nil, holder_user_id: nil,
      qr_code: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    if anonymize_responses
      update_unheld(RegistrationResponse.where(order_id: order.id), answer: {}, retention_anonymized_at: Time.current,
        updated_at: Time.current)
    end
    update_unheld(TicketTransfer.where(ticket_id: ticket_ids), recipient_email: replacement,
      recipient_name: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    deliveries = MessageDelivery.where(order_id: order.id, ticket_id: [nil, *ticket_ids])
      .or(MessageDelivery.where(ticket_id: ticket_ids))
    update_unheld(MessageProviderEvent.where(message_delivery_id: deliveries.select(:id)), payload: {},
      processing_error: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    update_unheld(deliveries.where(status: [:queued, :delayed, :failed]), status: MessageDelivery.statuses.fetch("cancelled"))
    update_unheld(deliveries, recipient: replacement, metadata: {},
      outbound_payload: {}, outbound_wire_body: nil, wire_body_digest: nil, last_error: nil,
      retention_anonymized_at: Time.current, updated_at: Time.current)
    update_unheld(Payment.where(order_id: order.id), provider_payload: {}, failure_message: nil, updated_at: Time.current)
    update_unheld(Refund.where(order_id: order.id), provider_payload: {}, reason: nil, failure_code: nil,
      failure_message: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    update_unheld(Dispute.where(order_id: order.id), provider_payload: {}, updated_at: Time.current)
    update_unheld(PaymentEvent.where(payment_id: order.payments.select(:id)), data: {}, updated_at: Time.current)
    update_unheld(WebhookEvent.where(id: PaymentEvent.where(payment_id: order.payments.select(:id)).select(:webhook_event_id)),
      payload: {}, last_error: nil, updated_at: Time.current)
    update_unheld(FeeComponent.where(order_id: order.id), metadata: {}, updated_at: Time.current)
    update_unheld(CardPresentPaymentAttempt.where(order_id: order.id), provider_response: {}, failure_message: nil,
      updated_at: Time.current)
    update_unheld(ReconciliationException.where(order_id: order.id), details: {}, updated_at: Time.current)
    update_unheld(EventCancellationRefundItem.where(order_id: order.id), last_error: nil, updated_at: Time.current)
    notes = if eligible_support_note_ids
      SupportNote.where(id: eligible_support_note_ids)
    else
      SupportNote.where(order_id: order.id, ticket_id: [nil, *ticket_ids])
        .or(SupportNote.where(ticket_id: ticket_ids))
    end
    update_unheld(notes, body: "[redacted]", retention_anonymized_at: Time.current, updated_at: Time.current)
    update_unheld(GuestListEntry.where(order_id: order.id), guest_email: nil, guest_name: "[redacted]",
      guest_phone: nil, notes: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    update_unheld(AdmissionAction.where(ticket_id: ticket_ids), attendee_snapshot: {}, metadata: {},
      retention_anonymized_at: Time.current, updated_at: Time.current)
    update_unheld(AcquisitionAttribution.where(order_id: order.id), visitor_hash: "[redacted]", campaign: nil,
      source: nil, medium: nil, updated_at: Time.current)
    update_unheld(MarketplaceFunnelEvent.where(order_id: order.id), visitor_hash: "[redacted]", campaign: nil,
      source: nil, medium: nil, updated_at: Time.current)
    update_unheld(AuditLog.where(auditable_type: "Order", auditable_id: order.id)
      .or(reconciliation_audits_for_orders([order.id])), ip_address: nil,
      before_data: {}, after_data: {}, metadata: {}, retention_anonymized_at: Time.current,
      updated_at: Time.current)
    reconciliation_digests_for_orders([order]).find_each do |delivery|
      next if held?(delivery)

      update_unheld(MessageProviderEvent.where(message_delivery_id: delivery.id), payload: {},
        processing_error: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
      delivery.update_columns(metadata: {}, outbound_payload: {}, outbound_wire_body: nil,
        wire_body_digest: nil, retention_anonymized_at: Time.current, updated_at: Time.current)
    end
    order.update_columns(buyer_email: replacement, buyer_name: "Deleted buyer", buyer_phone: nil,
      refund_reason: nil,
      marketing_opt_in: false, user_id: nil, guest_access_revoked_at: Time.current,
      retention_anonymized_at: Time.current, updated_at: Time.current)
  end

  def self.update_unheld(scope, **attributes)
    scope.find_each do |record|
      record.class.where(id: record.id).update_all(attributes) unless held?(record)
    end
  end

  def self.unresolved_money?(order)
    order.disputes.open.exists? || order.refunds.pending.exists? ||
      order.event.payouts.where(status: Payout.statuses.slice("pending", "processing", "held").values).exists?
  end

  def self.held?(record)
    if record.is_a?(Order)
      return true if LegalHold.for_order?(record)

      return reconciliation_digests_for_orders([record]).any? { |delivery| held?(delivery) }
    end
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
    scopes << ["user", record.author_user_id.to_s] if record.respond_to?(:author_user_id) && record.author_user_id
    scopes << ["user", record.accepted_by_user_id.to_s] if record.respond_to?(:accepted_by_user_id) && record.accepted_by_user_id
    scopes << ["user", record.initiated_by_user_id.to_s] if record.respond_to?(:initiated_by_user_id) && record.initiated_by_user_id
    %i[email buyer_email requester_email recipient recipient_email holder_email].each do |field|
      scopes << ["buyer_email", record.public_send(field).to_s.downcase] if
        record.respond_to?(field) && record.public_send(field).present?
    end
    return true if scopes.any? { |type, value| LegalHold.active.exists?(scope_type: type, scope_value: value) }

    return held?(record.event) if record.is_a?(OrganizerSalesExportRequest)
    if record.is_a?(AuditLog)
      subject = record.auditable
      return held?(subject) if subject
    end
    if record.respond_to?(:privacy_request) && record.privacy_request
      return true if held?(record.privacy_request)
    end
    if record.is_a?(MessageDelivery) && record.template == "refund_reconciliation_digest"
      references = Array(record.metadata["items"]).filter_map { |item| item["order_reference"] }
      return true if Order.where(reference: references).includes(:event).any? { |order| LegalHold.for_order?(order) }
    end
    related = record.order if record.respond_to?(:order)
    related ||= record.ticket&.order if record.respond_to?(:ticket)
    related ||= record.payment&.order if record.respond_to?(:payment)
    related ||= record.payment_event&.payment&.order if record.respond_to?(:payment_event)
    related ||= record.order_item&.order if record.respond_to?(:order_item)
    if record.respond_to?(:message_delivery) && record.message_delivery
      return true if held?(record.message_delivery)
    end
    return true if related && LegalHold.for_order?(related)

    if record.is_a?(WebhookEvent)
      return true if PaymentEvent.where(webhook_event_id: record.id).includes(payment: :order)
        .any? { |payment_event| payment_event.payment&.order && LegalHold.for_order?(payment_event.payment.order) }
    end

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
    return false if ORDER_PROVIDER_REFERENCES.any? { |column| order.public_send(column).present? }
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

    item_ids = OrderItem.where(order_id: order.id).select(:id)
    purge_scopes = [SeatHold.where(order_item_id: item_ids), CatalogItemHold.where(order_item_id: item_ids),
      InventoryHold.where(order_id: order.id), SeatHoldSession.where(order_id: order.id),
      PromoRedemption.where(order_id: order.id), ReferralAttribution.where(order_id: order.id),
      AcquisitionAttribution.where(order_id: order.id), MarketplaceFunnelEvent.where(order_id: order.id),
      OrderItem.where(order_id: order.id)]
    return false if purge_scopes.any? { |scope| scope.find_each.any? { |child| held?(child) } }

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
