# frozen_string_literal: true

# The durable proof that the money a payout sent came back exactly
# (CodeRabbit 4704933005): the amount that left, when it left and came back,
# and a SHA-256 digest of the bank's return reference (unique across all
# payouts). No personal data, so it is kept for the financial-record period
# while retention anonymizes the audit payloads that also carry the
# reference. Append-only; the database
# stamps recorded_at, checks the amount and times, and accepts a row only
# from PayoutReconciler (lib/financial_integrity.rb PAYOUT_ENTRY_SQL). The P4
# proof and the reversal fence read it (hafapass_payout_return_verified).
class PayoutReturnProof < ApplicationRecord
  KINDS = %w[verified_return accepted_transfer_return attached_return].freeze

  belongs_to :payout

  validates :kind, inclusion: { in: KINDS }
  validates :payout_id, uniqueness: true

  # The bank's return reference identifies one return (CodeRabbit
  # 4705527020): a unique index on the digest lets it back at most one
  # payout's proof, in every organization. Compared without case or spacing
  # differences, so "ret 0042" cannot back a second payout as "RET 0042".
  def self.reference_digest(reference)
    Digest::SHA256.hexdigest(reference.to_s.strip.gsub(/\s+/, " ").upcase)
  end

  def readonly?
    persisted? || super
  end

  def evidence_json
    { kind: kind, returned_amount_cents: returned_amount_cents, returned_at: returned_at&.utc&.iso8601(6),
      sent_at: sent_at&.utc&.iso8601(6), recorded_at: recorded_at&.utc&.iso8601(6) }
  end
end
