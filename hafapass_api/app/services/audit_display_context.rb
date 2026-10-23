# frozen_string_literal: true

# Capture display facts at the shared logger call site, while the subject still
# exists. Never inspect arbitrary associations or copy buyer/contact payloads.
class AuditDisplayContext
  LABELLED_TYPES = %w[TicketType PricingTier PromoCode CatalogItem CommunicationCampaign].freeze

  def self.call(action:, record:, event:)
    allowed = AuditActions.fetch(action)[:organization_fields][:metadata]
    return {} if allowed.empty?

    data = {}
    data[:event_title] = event.title if event
    if LABELLED_TYPES.include?(record.class.name)
      data[:subject_label] = record.is_a?(PromoCode) ? record.code : record.name
    end
    if record.is_a?(OrganizationMembership)
      data[:team_member_label] = record.invited_email.presence || [record.user&.first_name, record.user&.last_name].compact_blank.join(" ").presence || "team member ##{record.id}"
      data[:team_role] = record.role
    end
    if record.is_a?(EventStaffAssignment)
      data[:team_member_label] = [record.user.first_name, record.user.last_name].compact_blank.join(" ").presence || "staff member ##{record.user_id}"
      data[:team_role] = record.role
    end
    if record.is_a?(GuestListEntry)
      data[:ticket_type_label] = record.ticket_type.name
      data[:quantity] = record.quantity
    end
    if record.is_a?(CommunicationCampaign)
      data[:recipient_count] = record.recipient_count
    end
    if record.is_a?(Refund) || record.is_a?(Dispute) || record.is_a?(Payout) || record.is_a?(CardPresentPaymentAttempt)
      data[:amount_cents] = record.amount_cents
      data[:currency] = record.currency
    end
    order = if record.is_a?(Order)
      record
    elsif record.is_a?(Refund) || record.is_a?(Dispute) || record.is_a?(CardPresentPaymentAttempt)
      record.order
    end
    if order
      data[:order_reference] = order.reference
      data[:amount_cents] = order.total_cents if record.is_a?(Order)
      data[:currency] = order.currency if record.is_a?(Order)
    end
    data.select { |key, _value| allowed.include?(key.to_s) }
  end
end
