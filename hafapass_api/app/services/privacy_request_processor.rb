# frozen_string_literal: true

class PrivacyRequestProcessor
  class Blocked < StandardError; end

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
    ticket_ids = Ticket.where(order_id: order_ids).pluck(:id)
    payment_ids = Payment.where(order_id: order_ids).pluck(:id)
    delivery_ids = MessageDelivery.where(order_id: order_ids).or(
      MessageDelivery.where(ticket_id: ticket_ids)).pluck(:id)
    removable = @request.user ? {
      saved_events: EventFavorite.where(user_id: @request.user_id).count,
      organizer_follows: OrganizerFollow.where(user_id: @request.user_id).count,
      reminders: EventReminder.where(user_id: @request.user_id).count,
      uploads: ImageUploadReceipt.where(user_id: @request.user_id).count,
      wallet_passes: WalletPass.where(ticket_id: ticket_ids).count,
      clerk_identity: @request.user.clerk_id.present? ? 1 : 0
    } : {}
    {
      blockers: blockers,
      retained: [
        { table: "orders", count: orders.count,
          action: "anonymize", reason: "Seven-year accounting and tax record, then money rows remain" },
        { table: "payments", count: Payment.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep amount and provider reference; clear provider payload" },
        { table: "refunds", count: Refund.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep amount and status; clear provider payload" },
        { table: "disputes", count: Dispute.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep dispute amount and status; clear provider payload" },
        { table: "tickets", count: ticket_ids.size,
          action: "anonymize", reason: "Preserve admission evidence without attendee details" },
        { table: "registration responses", count: RegistrationResponse.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep question and acceptance evidence; clear answers" },
        { table: "message deliveries", count: MessageDelivery.where(order_id: order_ids).or(
          MessageDelivery.where(ticket_id: ticket_ids)).count,
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
          SupportNote.where(order_id: order_ids).count,
          action: "anonymize", reason: "Keep operational history; clear personal content" },
        { table: "marketing withdrawal proof", count: MarketingUnsubscribe.where(
          email: @request.requester_email.downcase).count,
          action: "keep", reason: "Withdrawal evidence remains for three years" },
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
          tickets: order.tickets.map { |ticket| ticket.attributes.slice("id", "attendee_name", "attendee_email",
            "holder_email", "status", "checked_in_at", "created_at") },
          registration_responses: RegistrationResponse.where(order_id: order.id).map(&:attributes),
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

  def execute!(actor:, request: nil)
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
      EmailService.send_privacy_request_confirmation_async(@request)
    rescue StandardError
      @request.update!(status: "partially_completed",
        result: @request.result.merge(manual_steps: Array(@request.result["manual_steps"]) | ["Confirmation email"]))
    end
    AuditLogger.record!(action: "privacy_request.executed", auditable: @request, actor: actor,
      metadata: { kind: @request.kind, status: @request.status, order_count: orders.count }, request: request)
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
      raise Blocked, "A legal hold or money operation now blocks deletion" if blockers.any?

      orders.each { |order| DataRetention.anonymize_order!(order) }
      WalletPass.where(ticket_id: Ticket.where(order_id: orders.map(&:id)).select(:id)).find_each(&:destroy!)
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
end
