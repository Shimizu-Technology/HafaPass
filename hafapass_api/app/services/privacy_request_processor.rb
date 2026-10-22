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
        Order.where(user_id: nil).where("lower(buyer_email) IN (?)", buyer_emails)).order(:id).to_a
    else
      [@request.order].compact
    end
  end

  def buyer_emails
    @buyer_emails ||= (Array(@request.verified_emails) + [@request.requester_email]).compact
      .map(&:downcase).uniq
  end

  def buyer_owned?(order)
    buyer_emails.include?(order.buyer_email.to_s.downcase)
  end

  def related_privacy_requests
    scope = PrivacyRequest.where("lower(requester_email) IN (?)", buyer_emails)
    @request.user_id ? scope.or(PrivacyRequest.where(user_id: @request.user_id)) : scope
  end

  def plan
    @plan ||= begin
      selected_orders = orders
      selected_tickets = selected_orders.flat_map do |order|
        order.tickets.select do |ticket|
          !ticket.transferred_away_from?(order) &&
            (ticket.holder_email.present? ? buyer_emails.include?(ticket.holder_email.downcase) :
              ((@request.user_id && ticket.holder_user_id == @request.user_id) ||
              (buyer_owned?(order) && ticket.holder_email.blank? && ticket.holder_user_id.nil? &&
                (ticket.attendee_email.blank? || buyer_emails.include?(ticket.attendee_email.downcase)))))
        end
      end
      ticket_ids = selected_tickets.map(&:id)
      order_note_ids = selected_orders.to_h do |order|
        ids = selected_tickets.select { |ticket| ticket.order_id == order.id }.map(&:id)
        notes = SupportNote.where(order_id: order.id, ticket_id: buyer_owned?(order) ? [nil, *ids] : ids)
          .or(SupportNote.where(ticket_id: ids))
        [order.id, notes.pluck(:id)]
      end
      response_order_ids = selected_orders.filter_map do |order|
        order.id if buyer_owned?(order) &&
          order.tickets.count == selected_tickets.count { |ticket| ticket.order_id == order.id }
      end
      order_ids = selected_orders.map(&:id)
      owned_order_ids = selected_orders.select { |order| buyer_owned?(order) }.map(&:id)
      delivery_ids = MessageDelivery.where(order_id: owned_order_ids, ticket_id: [nil, *ticket_ids])
        .or(MessageDelivery.where(ticket_id: ticket_ids)).pluck(:id)
      fragments = personal_tokens
      note_ids = if fragments.any?
        condition = fragments.map { "body ILIKE ?" }.join(" OR ")
        patterns = fragments.map { |value| "%#{ActiveRecord::Base.sanitize_sql_like(value)}%" }
        matched = SupportNote.where(event_id: selected_orders.map(&:event_id), order_id: nil, ticket_id: nil)
          .where(condition, *patterns)
        matched = matched.or(SupportNote.where(author_user_id: @request.user_id)) if @request.user_id
        matched.select { |note| (@request.user_id && note.author_user_id == @request.user_id) ||
          contains_personal_token?(note.body, fragments) }.map(&:id)
      else
        []
      end
      audit = AuditLog.where(auditable_type: "Order", auditable_id: owned_order_ids)
      audit = audit.or(AuditLog.where(auditable_type: "User", auditable_id: @request.user_id)) if @request.user_id
      audit = audit.or(AuditLog.where(auditable_type: "Ticket", auditable_id: ticket_ids))
      request_ids = related_privacy_requests.pluck(:id)
      audit = audit.or(AuditLog.where(auditable_type: "PrivacyRequest", auditable_id: request_ids))
      audit = audit.or(DataRetention.reconciliation_audits_for_orders(owned_order_ids))
      email_patterns = buyer_emails.map { |email| "%#{ActiveRecord::Base.sanitize_sql_like(email)}%" }
      audit_patterns = personal_tokens.map { |value| "%#{ActiveRecord::Base.sanitize_sql_like(value)}%" }
      audit_condition = audit_patterns.map do
        "metadata::text ILIKE ? OR before_data::text ILIKE ? OR after_data::text ILIKE ?"
      end.join(" OR ")
      matched_audit_ids = AuditLog.where(audit_condition, *audit_patterns.flat_map { |pattern| [pattern] * 3 })
        .select { |entry| contains_personal_token?([entry.metadata, entry.before_data, entry.after_data].to_json,
          personal_tokens) }.map(&:id)
      audit = audit.or(AuditLog.where(id: matched_audit_ids))
      metadata_condition = email_patterns.map { "metadata::text ILIKE ?" }.join(" OR ")
      Plan.new(orders: selected_orders, ticket_ids: ticket_ids, response_order_ids: response_order_ids,
        delivery_ids: delivery_ids, wallet_pass_ids: WalletPass.where(ticket_id: ticket_ids).pluck(:id),
        order_note_ids: order_note_ids, event_note_ids: note_ids, audit_ids: audit.pluck(:id),
        recipient_delivery_ids: MessageDelivery.where("lower(recipient) IN (?)", buyer_emails)
          .where.not(template: "privacy_request_confirmation").pluck(:id),
        metadata_delivery_ids: (MessageDelivery.where(metadata_condition, *email_patterns).pluck(:id) |
          DataRetention.reconciliation_digests_for_orders(selected_orders.select { |order| buyer_owned?(order) }).pluck(:id)))
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
      if DataRetention.reconciliation_digests_for_orders([order]).any? { |delivery| RetentionGuard.protected?(delivery) }
        items << "A hold or unresolved money covers a refund reconciliation digest for order #{order.reference}"
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
      deletion_disabled: DataRetention.dry_run?,
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
          email: buyer_emails).count,
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
          order: export_fields(order, "id", "reference", "buyer_email", "buyer_name", "buyer_phone",
            "created_at", "completed_at", "status", "subtotal_cents", "service_fee_cents", "total_cents",
            "refund_amount_cents", "marketing_opt_in").tap do |attributes|
              attributes.except!("buyer_email", "buyer_name", "buyer_phone", "marketing_opt_in") unless buyer_owned?(order)
              attributes["refund_reason"] = order.refund_reason if order.refund_reason.present? && buyer_owned?(order)
            end,
          tickets: order.tickets.filter_map do |ticket|
            if plan.ticket_ids.include?(ticket.id)
              export_fields(ticket, "id", "status", "checked_in_at", "created_at").tap do |fields|
                holder_owned = buyer_emails.include?(ticket.holder_email.to_s.downcase)
                attendee_owned = buyer_emails.include?(ticket.attendee_email.to_s.downcase)
                fields["holder_email"] = ticket.holder_email if holder_owned
                if attendee_owned
                  fields["attendee_email"] = ticket.attendee_email
                  fields["attendee_name"] = ticket.attendee_name
                end
              end
            elsif ticket.transferred?
              { "id" => ticket.id, "status" => "transferred" }
            end
          end,
          registration_responses: plan.response_order_ids.include?(order.id) ?
            RegistrationResponse.where(order_id: order.id).map(&:attributes) : [],
          refunds: order.refunds.map do |refund|
            export_fields(refund, "id", "amount_cents", "currency", "status", "created_at").tap do |fields|
              fields["reason"] = refund.reason if buyer_owned?(order) &&
                (refund.requested_by_id.nil? || refund.requested_by_id == @request.user_id)
            end
          end,
          disputes: order.disputes.map do |dispute|
            export_fields(dispute, "id", "amount_cents", "currency", "status", "created_at").tap do |fields|
              fields["reason"] = dispute.reason if buyer_owned?(order)
            end
          end
        }
      end,
      memberships: @request.user ? OrganizationMembership.where(user_id: @request.user_id).map(&:attributes) : [],
      organizer_profiles: @request.user ? OrganizerProfile.where(user_id: @request.user_id).map(&:attributes) : [],
      saved_events: @request.user ? EventFavorite.where(user_id: @request.user_id).map(&:attributes) : [],
      organizer_follows: @request.user ? OrganizerFollow.where(user_id: @request.user_id).map(&:attributes) : [],
      event_reminders: @request.user ? EventReminder.where(user_id: @request.user_id).map(&:attributes) : [],
      image_uploads: @request.user ? ImageUploadReceipt.where(user_id: @request.user_id).map(&:attributes) : [],
      marketing_withdrawals: MarketingUnsubscribe.where(email: buyer_emails).map(&:attributes),
      privacy_requests: @request.user ? PrivacyRequest.where(user_id: @request.user_id).map do |item|
        item.attributes.except("result")
      end : [@request.attributes.except("result")]
    }
  end

  def execute!(actor:, request: nil, confirm_dry_run: false)
    return preview if DataRetention.dry_run?

    raise Blocked, "Verify the requester before executing" unless @request.verified?
    raise Blocked, "The request has already been completed" if @request.executed_at?
    if @request.kind == "deletion" && blockers.any?
      raise Blocked, blockers.join("; ")
    end

    if @request.kind == "access"
      update_request_unless_protected!(status: "completed", executed_by: actor, executed_at: Time.current,
        result: { export_available_until: 7.days.from_now.iso8601 })
    else
      execute_deletion!(actor)
    end
    begin
      delivery = EmailService.send_privacy_request_confirmation_async(@request)
      MessageDeliveryJob.perform_now(delivery.id) if @request.kind == "deletion"
    rescue StandardError
      update_request_unless_protected!(status: "partially_completed",
        result: @request.result.merge(manual_steps: Array(@request.result["manual_steps"]) | ["Confirmation email"]))
    end
    AuditLogger.record!(action: "privacy_request.executed", auditable: @request, actor: actor,
      metadata: { kind: @request.kind, status: @request.status, order_count: orders.count }, request: request)
    if @request.kind == "deletion"
      confirmations = MessageDelivery.where(privacy_request_id: @request.id)
      DataRetention.update_unheld(confirmations.where(status: [:queued, :failed, :delayed]),
        status: MessageDelivery.statuses.fetch("cancelled"))
      DataRetention.update_unheld(MessageProviderEvent.where(message_delivery_id: confirmations.select(:id)), payload: {},
        processing_error: nil, updated_at: Time.current)
      DataRetention.update_unheld(confirmations, recipient: "deleted@privacy.invalid", metadata: {}, outbound_payload: {},
        outbound_wire_body: nil, wire_body_digest: nil, updated_at: Time.current)
      related_privacy_requests.find_each do |item|
        item.with_lock do
          if RetentionGuard.protected?(item)
            Rails.logger.info("[PrivacyRequest] skipped protected privacy_requests record")
            next
          end
          item.update_columns(requester_email: "deleted+request-#{item.id}@privacy.invalid",
            guest_challenge_digest: nil, guest_challenge_expires_at: nil, result: {},
            verified_emails: [], updated_at: Time.current)
        end
      end
    end
    @request
  end

  private

  def update_request_unless_protected!(**attributes)
    @request.with_lock do
      if RetentionGuard.protected?(@request)
        Rails.logger.info("[PrivacyRequest] skipped protected privacy_requests record")
        raise Blocked, "A protected request now blocks processing"
      end
      @request.update!(attributes)
    end
  end

  def export_fields(record, *columns)
    columns.to_h { |column| [column, record.public_send(column)] }
  end

  def execute_deletion!(actor)
    DataRetention.ensure_destructive_enabled!
    user = @request.user
    clerk_id = user&.clerk_id
    uploads = user ? ImageUploadReceipt.where(user_id: user.id).to_a : []
    LegalHold.with_retention_lock do
      PrivacyRequest.transaction do
        @request.lock!
        DataRetention.ensure_destructive_enabled!
        @orders = nil
        @plan = nil
        # Lock each rank across the whole request before descending to the next.
        organization_ids = orders.map { |order| order.event.organization_id }.uniq
        Organization.where(id: organization_ids).order(:id).lock("FOR UPDATE").load
        Event.where(id: orders.map(&:event_id)).order(:id).lock("FOR UPDATE").load
        orders.each(&:lock!)
        Ticket.where(order_id: orders.map(&:id)).order(:id).lock("FOR UPDATE").load
        raise Blocked, "A legal hold or money operation now blocks deletion" if blockers.any?
        raise Blocked, "A protected record now blocks deletion" if
          RetentionGuard.protected_batch?(orders).values.any?

        current_plan = plan
        owned_orders = current_plan.orders.select { |order| buyer_owned?(order) }
        owned_references = owned_orders.map(&:reference)
        personal_values = personal_tokens + owned_orders.flat_map { |order| [order.buyer_name, order.refund_reason] }
          .compact.reject { |value| value.length < 3 }
        buyer_emails.each { |email| PrivacyEmailSuppression.suppress!(email) }
        current_plan.orders.each do |order|
          written = DataRetention.anonymize_order!(order, buyer_owned: buyer_owned?(order),
            eligible_ticket_ids: order.tickets.where(id: current_plan.ticket_ids).pluck(:id),
            eligible_support_note_ids: current_plan.order_note_ids.fetch(order.id),
            anonymize_responses: current_plan.response_order_ids.include?(order.id),
            privacy_user_id: user&.id, privacy_emails: buyer_emails, privacy_names: personal_tokens)
          raise Blocked, "A protected order now blocks deletion" unless written
        end
        WalletPass.where(id: current_plan.wallet_pass_ids).find_each do |pass|
          pass.with_lock do
            if RetentionGuard.protected?(pass)
              Rails.logger.info("[PrivacyRequest] skipped protected wallet_passes record")
            else
              pass.destroy!
            end
          end
        end
        redact_references!(current_plan, user, owned_references, personal_values)
        if user
          [EventFavorite, OrganizerFollow, EventReminder].each do |model|
            model.where(user_id: user.id).find_each do |record|
              record.with_lock do
                if RetentionGuard.protected?(record)
                  Rails.logger.info("[PrivacyRequest] skipped protected #{model.table_name} record")
                else
                  record.delete
                end
              end
            end
          end
          DataRetention.update_unheld(OrganizationMembership.where(user_id: user.id), user_id: nil,
            invited_email: "deleted+user-#{user.id}@privacy.invalid", updated_at: Time.current)
          DataRetention.update_unheld(OrganizerProfile.where(user_id: user.id), user_id: nil, verification_notes: nil,
            updated_at: Time.current)
          user.with_lock do
            raise Blocked, "A protected account now blocks deletion" if RetentionGuard.protected?(user)

            user.update_columns(clerk_id: "deleted-user-#{user.id}", email: nil, first_name: nil,
              last_name: nil, phone: nil, updated_at: Time.current)
          end
        end
        update_request_unless_protected!(status: "completed", executed_by: actor, executed_at: Time.current,
          result: { retained_financial_orders: orders.count, removed_saved_records: true })
      end
    end

    manual = []
    uploads.each do |upload|
      begin
        upload.with_lock do
          LegalHold.with_retention_lock(organization_id: upload.event&.organization_id) do
            if RetentionGuard.protected?(upload)
              Rails.logger.info("[PrivacyRequest] skipped protected image_upload_receipts record")
              manual << "Protected S3 upload"
              next
            end
            S3Service.delete_upload!(upload.final_key)
            S3Service.delete_upload!(upload.source_key)
            DataRetention.update_unheld(Event.where(id: upload.event_id, cover_image_url: upload.public_url),
              cover_image_url: nil) if upload.event_id
            upload.destroy!
          end
        end
      rescue S3Service::UploadError, Aws::S3::Errors::ServiceError, Seahorse::Client::NetworkingError
        manual << "S3 upload deletion"
      end
    end
    if clerk_id
      manual << "Clerk user deletion" unless ClerkIdentity.delete_user(clerk_id)
    end
    update_request_unless_protected!(status: manual.any? ? "partially_completed" : "completed",
      result: @request.result.merge(manual_steps: manual.uniq, deleted_uploads: uploads.count -
        ImageUploadReceipt.where(id: uploads.map(&:id)).count))
  end

  def redact_references!(current_plan, _user, owned_references, personal_values)
    note_ids = current_plan.event_note_ids | current_plan.order_note_ids.values.flatten
    SupportNote.where(id: note_ids).find_each do |note|
      note.with_lock do
        if RetentionGuard.protected?(note)
          Rails.logger.info("[PrivacyRequest] skipped protected support_notes record")
          next
        end
        next unless (@request.user_id && note.author_user_id == @request.user_id) ||
          contains_personal_token?(note.body, personal_values)

        SupportNote.where(id: note.id).update_all(body: "[redacted]",
          retention_anonymized_at: Time.current, updated_at: Time.current)
      end
    end
    AuditLog.where(id: current_plan.audit_ids).find_each do |audit|
      audit.with_lock do
        if RetentionGuard.protected?(audit)
          Rails.logger.info("[PrivacyRequest] skipped protected audit_logs record")
          next
        end
        own_request = audit.auditable_type == "PrivacyRequest" &&
          related_privacy_requests.where(id: audit.auditable_id).exists?
        own_refund = audit.auditable_type == "Refund" &&
          Refund.where(id: audit.auditable_id, order_id: current_plan.orders.map(&:id),
            requested_by_id: [nil, @request.user_id]).exists?
        attrs = if own_request || own_refund
          { before_data: {}, after_data: {}, metadata: {} }
        else
          { before_data: redact_personal_value(audit.before_data, owned_references, personal_values),
            after_data: redact_personal_value(audit.after_data, owned_references, personal_values),
            metadata: redact_personal_value(audit.metadata, owned_references, personal_values) }
        end
        attrs[:ip_address] = nil if audit.actor_user_id == @request.user_id ||
          (audit.actor_user_id.nil? && own_request)
        attrs[:updated_at] = Time.current
        AuditLog.where(id: audit.id).update_all(attrs)
      end
    end
    MessageDelivery.where(id: current_plan.metadata_delivery_ids).find_each do |delivery|
      delivery.with_lock do
        if RetentionGuard.protected?(delivery)
          Rails.logger.info("[PrivacyRequest] skipped protected message_deliveries record")
          next
        end
        tokens = personal_values + Array(delivery.metadata["items"]).filter_map do |item|
          item["reason"] if item.is_a?(Hash) && owned_references.include?(item["order_reference"])
        end
        body = redact_personal_value(delivery.outbound_wire_body, owned_references, tokens)
        MessageDelivery.where(id: delivery.id).update_all(
          metadata: redact_personal_value(delivery.metadata, owned_references, tokens),
          outbound_payload: redact_personal_value(delivery.outbound_payload, owned_references, tokens),
          outbound_wire_body: body, wire_body_digest: body && Digest::SHA256.hexdigest(body),
          updated_at: Time.current)
        MessageProviderEvent.where(message_delivery_id: delivery.id).find_each do |event|
          event.with_lock do
            next if RetentionGuard.protected?(event)

            MessageProviderEvent.where(id: event.id).update_all(
              payload: redact_personal_value(event.payload, owned_references, tokens),
              processing_error: redact_personal_value(event.processing_error, owned_references, tokens),
              updated_at: Time.current)
          end
        end
      end
    end
    DataRetention.update_unheld(MessageProviderEvent.where(message_delivery_id: current_plan.recipient_delivery_ids),
      payload: {}, processing_error: nil, updated_at: Time.current)
    DataRetention.update_unheld(MessageDelivery.where(id: current_plan.recipient_delivery_ids),
        status: MessageDelivery.statuses.fetch("cancelled"), recipient: "deleted@privacy.invalid",
        metadata: {}, outbound_payload: {}, outbound_wire_body: nil, wire_body_digest: nil,
        last_error: nil, updated_at: Time.current)
  end

  def personal_tokens
    names = [@request.user&.first_name, @request.user&.last_name]
    [*buyer_emails, *buyer_emails.map { |email| email.split("@").first }, *names, names.compact.join(" ")].compact
      .map(&:strip).reject(&:blank?).uniq
  end

  def token_pattern(token)
    escaped = Regexp.escape(token)
    token.length < 3 ? /(?<![[:alnum:]])#{escaped}(?![[:alnum:]])/i : /#{escaped}/i
  end

  def contains_personal_token?(text, tokens)
    tokens.any? { |token| text.to_s.match?(token_pattern(token)) }
  end

  def redact_personal_value(value, owned_references, tokens)
    case value
    when Hash
      fields = value.transform_keys(&:to_s)
      reference = fields["order_reference"]
      return value if reference.present? && !owned_references.include?(reference)

      emails = %w[email buyer_email attendee_email holder_email recipient_email].filter_map do |key|
        fields[key]&.to_s&.downcase
      end
      user_ids = %w[user_id buyer_user_id attendee_user_id holder_user_id].filter_map do |key|
        fields[key]&.to_s
      end
      phones = %w[phone buyer_phone attendee_phone].filter_map { |key| fields[key]&.to_s }
      names = %w[name first_name last_name buyer_name attendee_name].filter_map do |key|
        fields[key]&.to_s&.downcase
      end
      requester_names = tokens.filter_map { |token| token.to_s.downcase if token.present? }
      requester_phone = @request.user&.phone.to_s
      identified = emails.any? || user_ids.any? || phones.any? || names.any?
      owned_identity = if emails.any?
        emails.intersect?(buyer_emails)
      elsif user_ids.any?
        @request.user_id && user_ids.include?(@request.user_id.to_s)
      else
        (requester_phone.present? && phones.include?(requester_phone)) ||
          names.intersect?(requester_names)
      end
      owned_item = owned_references.include?(reference) || owned_identity
      return value if identified && !owned_item

      value.each_with_object({}) do |(key, item), result|
        next if owned_item && %w[buyer_email buyer_name reason refund_reason dispute_reason].include?(key.to_s)
        next if owned_item && %w[first_name last_name name email phone user_id attendee_name attendee_email
          attendee_phone buyer_phone holder_email holder_user_id].include?(key.to_s.downcase)
        next if item.is_a?(String) && tokens.any? { |token| item.casecmp?(token) }

        redacted = redact_personal_value(item, owned_references, tokens)
        next if owned_item && redacted.is_a?(Hash) && redacted.empty?

        result[key] = redacted
      end
    when Array then value.map { |item| redact_personal_value(item, owned_references, tokens) }
    when String
      tokens.reduce(value) { |text, token| text.gsub(token_pattern(token), "[redacted]") }
    else value
    end
  end
end
