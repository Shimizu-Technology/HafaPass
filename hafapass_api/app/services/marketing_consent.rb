# frozen_string_literal: true

# A checkout choice applies to the buyer's address for the whole organizer.
# The newest completed checkout replaces an earlier choice; an explicit
# unsubscribe remains effective until a later affirmative checkout choice completes.
class MarketingConsent
  def self.latest_order(organization:, email:)
    Order.joins(:event).where(events: { organization_id: organization.id },
      status: [:completed, :partially_refunded, :refunded])
      .where("LOWER(orders.buyer_email) = ?", email.to_s.strip.downcase)
      .order(created_at: :desc, id: :desc).first
  end

  def self.opted_in?(organization:, email:)
    latest_order(organization: organization, email: email)&.marketing_opt_in? == true
  end
end
