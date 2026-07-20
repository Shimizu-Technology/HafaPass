# frozen_string_literal: true

require "digest"

class PolicyRegistry
  BUYER_TERMS_VERSION = "2026-07-pilot-draft"
  ORGANIZER_AGREEMENT_VERSION = "2026-07-pilot-draft"

  BUYER_TERMS_CANONICAL = [
    BUYER_TERMS_VERSION,
    "buyer-terms",
    "privacy",
    "refund-cancellation",
    "acceptable-use",
    "data-retention"
  ].join("|").freeze
  ORGANIZER_AGREEMENT_CANONICAL = [
    ORGANIZER_AGREEMENT_VERSION,
    "organizer-agreement",
    "permitted-events",
    "refund-obligations",
    "payout-reserves",
    "data-protection"
  ].join("|").freeze

  def self.buyer_terms
    { version: BUYER_TERMS_VERSION, digest: Digest::SHA256.hexdigest(BUYER_TERMS_CANONICAL) }
  end

  def self.organizer_agreement
    { version: ORGANIZER_AGREEMENT_VERSION, digest: Digest::SHA256.hexdigest(ORGANIZER_AGREEMENT_CANONICAL) }
  end
end
