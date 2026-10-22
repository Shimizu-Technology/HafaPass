# frozen_string_literal: true

class FeeChangeNotice < ApplicationRecord
  belongs_to :fee_change
  belongs_to :organization
  belongs_to :owner, class_name: "User"
  belongs_to :event

  def effective_owner?
    owner.email.present? && owner.email.casecmp?(recipient_email) &&
      organization.organization_memberships.where(user_id: owner.id, role: :owner).effective.exists?
  end

  def example(terms)
    quote = Commerce::ServiceFee.quote(unit_price_cents: 2500, buyer_fee_percent: buyer_fee_percent,
      terms: Commerce::ServiceFee::Terms.new(percent: terms.fetch("service_fee_percent").to_d,
        flat_cents: terms.fetch("service_fee_flat_cents").to_i))
    { all_in_price_cents: quote.all_in_price_cents, service_fee_cents: quote.buyer_fee_cents }
  end
end
