# frozen_string_literal: true

class GuestListEntry < ApplicationRecord
  include OperationalAuditable

  audits_operations :guest_list,
    fields: %w[event_id ticket_type_id quantity redeemed order_id],
    observe: %w[guest_name guest_email guest_phone notes]

  # Orders need a buyer email; a guest without one gets a reserved, never-routable
  # address (RFC 2606 ".invalid") so no ticket email leaves HåfaPass for them.
  PLACEHOLDER_EMAIL = "guest-list@hafapass.invalid"

  belongs_to :event
  belongs_to :ticket_type
  belongs_to :order, optional: true

  validates :guest_name, presence: true
  validates :quantity, presence: true, numericality: { greater_than: 0, less_than_or_equal_to: 10 }

  validate :ticket_type_matches_event

  scope :unredeemed, -> { where(redeemed: false) }
  scope :redeemed, -> { where(redeemed: true) }

  def ticket_type_matches_event
    if ticket_type && ticket_type.event_id != event_id
      errors.add(:ticket_type, "must belong to this event")
    end
  end

  def redeem!(order)
    update!(
      redeemed: true,
      order: order
    )
  end

  private

  def operational_audit_action(operation)
    return "guest_list.redeemed" if operation == :update && saved_change_to_redeemed? && redeemed?

    super
  end
end
