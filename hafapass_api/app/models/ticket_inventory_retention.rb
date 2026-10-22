# frozen_string_literal: true

class TicketInventoryRetention < ApplicationRecord
  belongs_to :ticket
  belongs_to :refund, optional: true
  belongs_to :dispute, optional: true
  belongs_to :reconciliation_exception

  validates :ticket_id, uniqueness: true
  validates :retained_at, presence: true
  validate :financial_origin_matches

  before_update :prevent_mutation
  after_create -> { Wallet::PassSync.tickets_changed(ticket_id) }
  before_destroy :prevent_mutation

  private

  def financial_origin_matches
    if refund.present? == dispute.present?
      errors.add(:base, "Exactly one refund or dispute must originate the retention")
      return
    end
    origin = refund || dispute
    errors.add(:base, "Retention requires an existing financial operation and ticket") unless origin.persisted? && ticket&.persisted?
    if origin.order_id != ticket&.order_id || reconciliation_exception&.order_id != ticket&.order_id
      errors.add(:base, "Retention evidence must belong to the ticket's order")
    end
    unless refund ? refund.succeeded? : dispute.lost?
      errors.add(:base, "Retention requires a succeeded refund or lost dispute")
    end
  end

  def prevent_mutation
    errors.add(:base, "Inventory retention evidence is append-only")
    throw(:abort)
  end
end
