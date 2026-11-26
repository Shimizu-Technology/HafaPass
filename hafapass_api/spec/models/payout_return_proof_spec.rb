# frozen_string_literal: true

require "rails_helper"

# CodeRabbit 4706251644: one bank return is one digest, however its
# reference was typed.
RSpec.describe PayoutReturnProof do
  describe ".reference_digest" do
    it "is the same for references that differ only in case, spacing anywhere, or compatibility forms" do
      variants = ["RET123", "RET 123", "ret123", " r e t 1 2 3 ", "RET\t12\n3", "RET 123", "RET 123",
        "RET​123", "ＲＥＴ１２３", "Ret　123"]
      expect(variants.map { |reference| described_class.reference_digest(reference) }.uniq)
        .to eq([Digest::SHA256.hexdigest("RET123")])
    end

    it "keeps punctuation and characters that can distinguish two bank references" do
      digests = %w[RET123 RET-123 RET1234 RET12.3 RFT123].map { |reference| described_class.reference_digest(reference) }
      expect(digests.uniq.size).to eq(5)
    end

    # CodeRabbit 4707205476: normalized again once separators are removed,
    # so a combining accent a space kept apart from its letter composes.
    it "composes an accent that a separator kept apart, and stays stable" do
      composed = described_class.canonical_reference("RET-\u00C942")
      expect(described_class.canonical_reference("RET-E \u030142")).to eq(composed)
      expect(described_class.canonical_reference("ret-e\u200B\u0301 42")).to eq(composed)
      expect(described_class.reference_digest("RET-E \u030142")).to eq(Digest::SHA256.hexdigest("RET-\u00C942"))
      expect(described_class.canonical_reference(composed)).to eq(composed)
      expect(described_class.reference_digest("RET-42")).not_to eq(described_class.reference_digest("RET42"))
    end

    it "refuses a reference with no visible character" do
      ["", "   ", "​ "].each do |reference|
        expect { described_class.reference_digest(reference) }.to raise_error(ArgumentError, /visible character/)
      end
    end
  end
end
