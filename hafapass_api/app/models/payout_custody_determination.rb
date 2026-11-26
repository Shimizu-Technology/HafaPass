# frozen_string_literal: true

# One frozen answer per payout to "did this payout's finalized settlement
# version fund money HåfaPass held as Stripe custody?" (design §8.6, R2-2).
# Append-only; the database stamps determined_at and refuses changes
# (lib/financial_integrity.rb CUSTODY_SQL). PayoutCustody is the only writer.
class PayoutCustodyDetermination < ApplicationRecord
  DETERMINATIONS = %w[stripe_custody non_custodial ambiguous].freeze
  BASES = %w[recorded_at_paid derived_history].freeze

  belongs_to :payout

  validates :determination, inclusion: { in: DETERMINATIONS }
  validates :basis, inclusion: { in: BASES }
  validates :payout_id, uniqueness: true

  def readonly?
    persisted? || super
  end
end
