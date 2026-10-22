# frozen_string_literal: true

class PrivacyRequestProcessor
  class Blocked < StandardError; end
  Plan = Data.define(:orders, :ticket_ids, :response_order_ids, :delivery_ids, :wallet_pass_ids,
    :order_note_ids, :event_note_ids, :audit_ids, :recipient_delivery_ids, :metadata_delivery_ids)

  def initialize(privacy_request)
    @request = privacy_request
  end

  def orders
    @orders ||= if @request.user_id
      Order.where(user_id: @request.user_id).or(
        Order.where(user_id: nil).where("lower(buyer_email) = ?", @request.requester_email.downcase)).order(:id).to_a
    else
      [@request.order].compact
    end
  end

  def plan
    @plan ||= begin
      selected_orders = orders
      selected_tickets = selected_orders.flat_map do |order|
        order.tickets.select do |ticket|
          !ticket.transferred_away_from?(order) &&
            (ticket.holder_email.blank? || ticket.holder_email.casecmp?(@request.requester_email))
        end
      end
      ticket_ids = selected_tickets.map(&:id)
      order_note_ids = selected_orders.to_h do |order|
        ids = selected_tickets.select { |ticket| ticket.order_id == order.id }.map(&:id)
        notes = SupportNote.where(order_id: order.id, ticket_id: [nil, *ids])
          .or(SupportNote.where(ticket_id: ids))
        [order.id, notes.pluck(:id)]
      end
      response_order_ids = selected_orders.filter_map do |order|
        order.id if order.tickets.count == selected_tickets.count { |ticket| ticket.order_id == order.id }
      end
      order_ids = selected_orders.map(&:id)
      delivery_ids = MessageDelivery.where(order_id: order_ids, ticket_id: [nil, *ticket_ids])
        .or(MessageDelivery.where(ticket_id: ticket_ids)).pluck(:id)
      email = @request.requester_email.downcase
      fragments = [email, @request.user&.first_name, @request.user&.last_name].compact
        .reject { |value| value.length < 3 }
      note_ids = if fragments.any?
        condition = fragments.map { "body ILIKE ?" }.join(" OR ")
        patterns = fragments.map { |value| "%#{ActiveRecord::Base.sanitize_sql_like(value)}%" }
        matched = SupportNote.where(event_id: selected_orders.map(&:event_id), order_id: nil, ticket_id: nil)
          .where(condition, *patterns)
        matched = matched.or(SupportNote.where(author_user_id: @request.user_id)) if @request.user_id
        matched.pluck(:id)
      else
        []
      end
      audit = AuditLog.where(auditable_type: "Order", auditable_id: order_ids)
      audit = audit.or(AuditLog.where(auditable_type: "User", auditable_id: @request.user_id)) if @request.user_id
      audit = audit.or(AuditLog.where(auditable_type: "Ticket", auditable_id: ticket_ids))
      request_ids = @request.user_id ? PrivacyRequest.where(user_id: @request.user_id).pluck(:id) : [@request.id]
      audit = audit.or(AuditLog.where(auditable_type: "PrivacyRequest", auditable_id: request_ids))
      audit = audit.or(DataRetention.reconciliation_audits_for_orders(order_ids))
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(email)}%"
      audit = audit.or(AuditLog.where("metadata::text ILIKE ? OR before_data::text ILIKE ? OR after_data::text ILIKE ?",
        pattern, pattern, pattern))
      Plan.new(orders: selected_orders, ticket_ids: ticket_ids, response_order_ids: response_order_ids,
        delivery_ids: delivery_ids, wallet_pass_ids: WalletPass.where(ticket_id: ticket_ids).pluck(:id),
        order_note_ids: order_note_ids, event_note_ids: note_ids, audit_ids: audit.pluck(:id),
        recipient_delivery_ids: MessageDelivery.where("lower(recipient) = ?", email)
          .where.not(template: "privacy_request_confirmation").pluck(:id),
        metadata_delivery_ids: (MessageDelivery.where("metadata::text ILIKE ?", pattern).pluck(:id) |
          DataRetention.reconciliation_digests_for_orders(selected_orders).pluck(:id)))
    end
  end

  def blockers
    items = []
    items << "A legal hold covers the account" if @request.user && LegalHold.for_user?(@request.user)
    if LegalHold.active.exists?(scope_type: "buyer_email", scope_value: @request.requester_email.downcase)
      items << "A legal hold covers the verified email address"
    end
    if @request.user && (@request.user.admin? || @request.user.support?)
      items << "Transfer the platform role before deleting this account"
    end
    orders.each do |order|
      items << "Order #{order.reference} is under legal hold" if LegalHold.for_order?(order)
      if DataRetention.reconciliation_digests_for_orders([order]).any? { |delivery| DataRetention.held?(delivery) }
        items << "A legal hold covers a refund reconciliation digest for order #{order.reference}"
      end
      items << "Order #{order.reference} has an open dispute, pending refund, or pending payout" if
        DataRetention.unresolved_money?(order)
      items << "Order #{order.reference} has tickets for an upcoming event" if
        order.event.starts_at && order.event.starts_at > Time.current && order.tickets.exists?
    end
    if @request.user && OrganizationMembership.where(user_id: @request.user.id).effective.exists?
      items << "The organizer account has an active organization role; transfer or close it first"
    end
    if @request.user
      linked = [EventFavorite, OrganizerFollow, EventReminder, ImageUploadReceipt]
      held_activity = linked.any? do |model|
        model.where(user_id: @request.user_id).find_each.any? { |record| DataRetention.held?(record) }
      end
      items << "A legal hold covers saved activity or an upload" if held_activity
    end
    items.uniq
  end

  def preview
    order_ids = orders.map(&:id)
    ticket_ids = plan.ticket_ids
    payment_ids = Payment.where(order_id: order_ids).pluck(:id)
    delivery_ids = plan.delivery_ids
    removable = @request.user ? {
      saved_events: EventFavorite.where(user_id: @request.user_id).count,
      organizer_follows: OrganizerFollow.where(user_id: @request.user_id).count,
      reminders: EventReminder.where(user_id: @request.user_id).count,
      uploads: ImageUploadReceipt.where(user_id: @request.user_id).count,
      wallet_passes: plan.wallet_pass_ids.size,
      clerk_identity: @request.user.clerk_id.present? ? 1 : 0
    } : { wallet_passes: plan.wallet_pass_ids.size }
    {
      blockers: blockers,
      dry_run: DataRetention.dry_run?,
      retained: [
        { table: "orders", count: orders.count,
          action: "anonymize", reason: "Seven-year accounting and tax record, then money rows remain" },
        { table: "payments", count: Payment.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep amount and provider reference; clear provider payload" },
        { table: "refunds", count: Refund.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep amount and status; clear provider payload" },
        { table: "cancellation refund items", count: EventCancellationRefundItem.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep amount and status; clear error details" },
        { table: "disputes", count: Dispute.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep dispute amount and status; clear provider payload" },
        { table: "tickets", count: ticket_ids.size,
          action: "anonymize", reason: "Preserve admission evidence without attendee details" },
        { table: "registration responses", count: RegistrationResponse.where(order_id: plan.response_order_ids).count,
          action: "anonymize", reason: "Keep question and acceptance evidence; clear answers" },
        { table: "message deliveries", count: delivery_ids.size,
          action: "anonymize", reason: "Keep send outcome; clear recipient and body" },
        { table: "message provider events", count: MessageProviderEvent.where(message_delivery_id: delivery_ids).count,
          action: "anonymize", reason: "Keep delivery evidence; clear payload" },
        { table: "payment events and webhooks", count: PaymentEvent.where(payment_id: payment_ids).count,
          action: "anonymize", reason: "Keep event type and amount; clear payload" },
        { table: "fees and reconciliation", count: FeeComponent.where(order_id: order_ids).count +
          ReconciliationException.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep amounts and status; clear free-form details" },
        { table: "card-present attempts", count: CardPresentPaymentAttempt.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep payment amount and status; clear provider response" },
        { table: "ticket transfers and admission", count: TicketTransfer.where(ticket_id: ticket_ids).count +
          AdmissionAction.where(ticket_id: ticket_ids).count,
          action: "anonymize", reason: "Keep admission outcome; clear attendee and recipient details" },
        { table: "guest list, registration and support", count: GuestListEntry.where(order_id: order_ids).count +
          plan.order_note_ids.values.sum(&:size),
          action: "anonymize", reason: "Keep operational history; clear personal content" },
        { table: "marketing withdrawal proof", count: MarketingUnsubscribe.where(
          email: @request.requester_email.downcase).count,
          action: "keep", reason: "Withdrawal evidence remains for three years" },
        { table: "event-only support notes", count: plan.event_note_ids.size,
          action: "anonymize", reason: "Notes that mention the requester are redacted" },
        { table: "requester audit logs", count: plan.audit_ids.size,
          action: "anonymize", reason: "Requester metadata is redacted" },
        { table: "recipient message metadata", count: (plan.recipient_delivery_ids | plan.metadata_delivery_ids).size,
          action: "anonymize", reason: "Future sends to the deleted address are suppressed" },
        { table: "account and organizer audit links", count: @request.user ? 1 : 0,
          action: "anonymize", reason: "Foreign keys and audit history require a pseudonymous row" }
      ],
      deleted: removable.map { |table, count| { table: table.to_s, count: count, action: "delete",
        reason: "No accounting retention duty" } }
    }
  end

  def export
    {
      generated_at: Time.current.iso8601,
      account: @request.user&.attributes&.slice("id", "email", "first_name", "last_name", "phone", "created_at"),
      orders: orders.map do |order|
        {
          order: order.attributes.slice("id", "reference", "buyer_email", "buyer_name", "buyer_phone",
            "created_at", "completed_at", "status", "subtotal_cents", "service_fee_cents", "total_cents",
            "refund_amount_cents", "marketing_opt_in"),
          tickets: order.tickets.filter_map do |ticket|
            if plan.ticket_ids.include?(ticket.id)
              ticket.attributes.slice("id", "attendee_name", "attendee_email", "holder_email",
                "status", "checked_in_at", "created_at")
            elsif ticket.transferred?
              { "id" => ticket.id, "status" => "transferred" }
            end
          end,
          registration_responses: plan.response_order_ids.include?(order.id) ?
            RegistrationResponse.where(order_id: order.id).map(&:attributes) : [],
          refunds: order.refunds.map { |refund| refund.attributes.except("provider_payload") },
          disputes: order.disputes.map { |dispute| dispute.attributes.except("provider_payload") }
        }
      end,
      memberships: @request.user ? OrganizationMembership.where(user_id: @request.user_id).map(&:attributes) : [],
      organizer_profiles: @request.user ? OrganizerProfile.where(user_id: @request.user_id).map(&:attributes) : [],
      saved_events: @request.user ? EventFavorite.where(user_id: @request.user_id).map(&:attributes) : [],
      organizer_follows: @request.user ? OrganizerFollow.where(user_id: @request.user_id).map(&:attributes) : [],
      event_reminders: @request.user ? EventReminder.where(user_id: @request.user_id).map(&:attributes) : [],
      image_uploads: @request.user ? ImageUploadReceipt.where(user_id: @request.user_id).map(&:attributes) : [],
      marketing_withdrawals: MarketingUnsubscribe.where(email: @request.requester_email.downcase).map(&:attributes),
      privacy_requests: @request.user ? PrivacyRequest.where(user_id: @request.user_id).map do |item|
        item.attributes.except("result")
      end : [@request.attributes.except("result")]
    }
  end

  def execute!(actor:, request: nil, confirm_dry_run: false)
    return preview if DataRetention.dry_run? && !confirm_dry_run

    raise Blocked, "Verify the requester before executing" unless @request.verified?
    raise Blocked, "The request has already been completed" if @request.executed_at?
    if @request.kind == "deletion" && blockers.any?
      raise Blocked, blockers.join("; ")
    end

    if @request.kind == "access"
      @request.update!(status: "completed", executed_by: actor, executed_at: Time.current,
        result: { export_available_until: 7.days.from_now.iso8601 })
    else
      execute_deletion!(actor)
    end
    begin
      delivery = EmailService.send_privacy_request_confirmation_async(@request)
      MessageDeliveryJob.perform_now(delivery.id) if @request.kind == "deletion"
    rescue StandardError
      @request.update!(status: "partially_completed",
        result: @request.result.merge(manual_steps: Array(@request.result["manual_steps"]) | ["Confirmation email"]))
    end
    AuditLogger.record!(action: "privacy_request.executed", auditable: @request, actor: actor,
      metadata: { kind: @request.kind, status: @request.status, order_count: orders.count }, request: request)
    if @request.kind == "deletion"
      confirmations = MessageDelivery.where(privacy_request_id: @request.id)
      confirmations.where(status: [:queued, :failed, :delayed])
        .update_all(status: MessageDelivery.statuses.fetch("cancelled"))
      MessageProviderEvent.where(message_delivery_id: confirmations.select(:id)).update_all(payload: {},
        processing_error: nil, updated_at: Time.current)
      confirmations.update_all(recipient: "deleted@privacy.invalid", metadata: {}, outbound_payload: {},
        outbound_wire_body: nil, wire_body_digest: nil, updated_at: Time.current)
      @request.update_columns(requester_email: "deleted+request-#{@request.id}@privacy.invalid",
        guest_challenge_digest: nil, updated_at: Time.current)
    end
    @request
  end

  private

  def execute_deletion!(actor)
    user = @request.user
    clerk_id = user&.clerk_id
    uploads = user ? ImageUploadReceipt.where(user_id: user.id).to_a : []
    PrivacyRequest.transaction do
      @request.lock!
      @orders = nil
      @plan = nil
      orders.each(&:lock!)
      Ticket.where(order_id: orders.map(&:id)).order(:id).lock("FOR UPDATE").load
      raise Blocked, "A legal hold or money operation now blocks deletion" if blockers.any?

      current_plan = plan
      PrivacyEmailSuppression.suppress!(@request.requester_email)
      current_plan.orders.each do |order|
        DataRetention.anonymize_order!(order,
          eligible_ticket_ids: order.tickets.where(id: current_plan.ticket_ids).pluck(:id),
          eligible_support_note_ids: current_plan.order_note_ids.fetch(order.id),
          anonymize_responses: current_plan.response_order_ids.include?(order.id))
      end
      WalletPass.where(id: current_plan.wallet_pass_ids).find_each(&:destroy!)
      redact_references!(current_plan, user)
      if user
        EventFavorite.where(user_id: user.id).delete_all
        OrganizerFollow.where(user_id: user.id).delete_all
        EventReminder.where(user_id: user.id).delete_all
        OrganizationMembership.where(user_id: user.id).update_all(user_id: nil,
          invited_email: "deleted+user-#{user.id}@privacy.invalid", updated_at: Time.current)
        OrganizerProfile.where(user_id: user.id).update_all(user_id: nil, verification_notes: nil,
          updated_at: Time.current)
        user.update_columns(clerk_id: "deleted-user-#{user.id}", email: nil, first_name: nil,
          last_name: nil, phone: nil, updated_at: Time.current)
      end
      @request.update!(status: "completed", executed_by: actor, executed_at: Time.current,
        result: { retained_financial_orders: orders.count, removed_saved_records: true })
    end

    manual = []
    uploads.each do |upload|
      begin
        S3Service.delete_upload!(upload.final_key)
        S3Service.delete_upload!(upload.source_key)
        Event.where(id: upload.event_id, cover_image_url: upload.public_url).update_all(cover_image_url: nil) if upload.event_id
        upload.destroy!
      rescue S3Service::UploadError, Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError
        manual << "S3 upload deletion"
      end
    end
    if clerk_id
      manual << "Clerk user deletion" unless ClerkIdentity.delete_user(clerk_id)
    end
    @request.update!(status: manual.any? ? "partially_completed" : "completed",
      result: @request.result.merge(manual_steps: manual.uniq, deleted_uploads: uploads.count -
        ImageUploadReceipt.where(id: uploads.map(&:id)).count))
  end

  def redact_references!(current_plan, _user)
    SupportNote.where(id: current_plan.event_note_ids).update_all(body: "[redacted]",
      retention_anonymized_at: Time.current, updated_at: Time.current)
    AuditLog.where(id: current_plan.audit_ids).update_all(ip_address: nil,
      before_data: {}, after_data: {}, metadata: {}, retention_anonymized_at: Time.current,
      updated_at: Time.current)
    MessageDelivery.where(id: current_plan.metadata_delivery_ids).update_all(metadata: {},
      outbound_payload: {}, outbound_wire_body: nil, wire_body_digest: nil, updated_at: Time.current)
    MessageDelivery.where(id: current_plan.recipient_delivery_ids)
      .update_all(status: MessageDelivery.statuses.fetch("cancelled"), recipient: "deleted@privacy.invalid",
        metadata: {}, outbound_payload: {}, outbound_wire_body: nil, wire_body_digest: nil,
        last_error: nil, updated_at: Time.current)
  end
end
