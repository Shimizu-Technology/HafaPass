# frozen_string_literal: true

class RegistrationResponse < ApplicationRecord
  include AppendOnlyRecord

  OPTION_KIND_VALUES = RegistrationQuestion::OPTION_KINDS.map { |kind| RegistrationQuestion.kinds.fetch(kind) }.freeze

  belongs_to :order
  belongs_to :registration_question
  # Present for questions asked once per ticket; order-wide answers have none.
  belongs_to :ticket, optional: true

  validates :prompt_snapshot, :kind_snapshot, :answered_at, presence: true
  validates :registration_question_id, uniqueness: { scope: :order_id, conditions: -> { where(ticket_id: nil) } },
    if: -> { ticket_id.nil? }
  validates :registration_question_id, uniqueness: { scope: :ticket_id }, if: -> { ticket_id.present? }
  validates :required_snapshot, inclusion: { in: [true, false] }
  validates :options_snapshot, presence: true, if: -> { OPTION_KIND_VALUES.include?(kind_snapshot) }
  validate :ticket_belongs_to_order

  scope :order_scoped, -> { where(ticket_id: nil) }

  private

  def ticket_belongs_to_order
    return if ticket.nil? || ticket.order_id == order_id

    errors.add(:ticket, "must belong to this order")
  end
end
