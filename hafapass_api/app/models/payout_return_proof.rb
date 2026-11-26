# frozen_string_literal: true

# The durable proof that the money a payout sent came back exactly
# (CodeRabbit 4704933005): the amount that left, when it left and came back,
# and a SHA-256 digest of the bank's return reference. No personal data, so
# it is kept for the financial-record period while retention anonymizes the
# audit payloads that also carry the reference. Append-only; the database
# stamps recorded_at, checks the amount and times, and accepts a row only
# from PayoutReconciler (lib/financial_integrity.rb PAYOUT_ENTRY_SQL). The P4
# proof and the reversal fence read it (hafapass_payout_return_verified).
class PayoutReturnProof < ApplicationRecord
  KINDS = %w[verified_return accepted_transfer_return attached_return].freeze

  belongs_to :payout

  validates :kind, inclusion: { in: KINDS }
  validates :payout_id, uniqueness: true

  def self.reference_digest(reference)
    Digest::SHA256.hexdigest(reference.to_s.strip)
  end

  def readonly?
    persisted? || super
  end

  def evidence_json
    { kind: kind, returned_amount_cents: returned_amount_cents, returned_at: returned_at&.utc&.iso8601(6),
      sent_at: sent_at&.utc&.iso8601(6), recorded_at: recorded_at&.utc&.iso8601(6) }
  end
end
