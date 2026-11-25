# frozen_string_literal: true

# One returned-money movement on a never-fulfilled capture
# (docs/design/never-fulfilled-captures.md §5.2). Append-only: the database
# trigger (lib/financial_integrity.rb) checks the movement, the sequence, the
# gross identity and the cumulative bounds. Commerce::BuyerReturnPostings is
# the only writer.
class BuyerReturnPosting < ApplicationRecord
  FORWARD_KINDS = %w[refund dispute_loss].freeze
  REVERSAL_KINDS = %w[dispute_loss_reversal refund_reversal].freeze
  KINDS = (FORWARD_KINDS + REVERSAL_KINDS).freeze
  # Frozen tie-break for facts first posted together (§5.2).
  KIND_RANK = { "refund" => 0, "dispute_loss" => 1, "dispute_loss_reversal" => 2, "refund_reversal" => 2 }.freeze
  COMPONENTS = %i[proceeds_cents fee_cents organizer_fee_cents tax_cents].freeze

  belongs_to :unfulfilled_capture, foreign_key: :never_fulfilled_capture_id, inverse_of: :buyer_return_postings
  belongs_to :source, polymorphic: true
  belongs_to :reverses_posting, class_name: "BuyerReturnPosting", optional: true

  scope :in_sequence, -> { order(:sequence) }
  scope :recognized, -> { where(recognition_state: "recognized") }

  def readonly?
    persisted? || super
  end

  def reversal?
    REVERSAL_KINDS.include?(kind)
  end

  def components
    COMPONENTS.map { |column| public_send(column) }
  end
end
