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
  # payout's proof, in every organization. CodeRabbit 4706251644: the digest
  # is of its canonical form, compatibility-normalized (NFKC, so a
  # full-width "ＲＥＴ１２３" is "RET123"), with every whitespace and
  # invisible format character removed wherever it occurs and upcased. So
  # "ret 0042", "RET0042", "RET\u00A00042" and "R E T 0 0 4 2" are one
  # return and cannot back a second payout. Punctuation is kept: "RET-42"
  # and "RET42" may be different bank references. The proof table is new in
  # this unreleased migration, so no stored digest predates this form.
  # CodeRabbit 4707205476: normalized again after the separators are removed
  # and the case is folded, so a combining mark a separator kept apart
  # ("RET-E \u0301" + "42") composes with its letter as in "RET-É42". The
  # result is stable: canonical_reference(canonical_reference(x)) ==
  # canonical_reference(x).
  def self.canonical_reference(reference)
    strip = ->(text) { text.gsub(/[[:space:]\p{Cf}]/, "") }
    strip.call(strip.call(reference.to_s.unicode_normalize(:nfkc)).upcase.unicode_normalize(:nfkc))
  end

  def self.reference_digest(reference)
    canonical = canonical_reference(reference)
    raise ArgumentError, "A return reference needs a visible character" if canonical.empty?

    Digest::SHA256.hexdigest(canonical)
  end

  def readonly?
    persisted? || super
  end

  def evidence_json
    { kind: kind, returned_amount_cents: returned_amount_cents, returned_at: returned_at&.utc&.iso8601(6),
      sent_at: sent_at&.utc&.iso8601(6), recorded_at: recorded_at&.utc&.iso8601(6) }
  end
end
