# frozen_string_literal: true

require "rails_helper"

RSpec.describe BackupWithholding do
  let!(:tax) { create(:organizer_tax_information) }

  it "allows check and Guam phone numbers but flags formatted and known bare taxpayer IDs" do
    expect(described_class.safe_text?("Check 123456789 cleared")).to be(true)
    expect(described_class.safe_text?("Call 6715551234 or 671-555-1234")).to be(true)
    expect(described_class.safe_text?("TIN 123-45-6789")).to be(false)
    expect(described_class.safe_text?("EIN 12-3456789")).to be(false)
    expect(described_class.safe_text?("TIN #{tax.tin}")).to be(false)
    expect(OrganizerTaxInformation.where(tin_digest: OrganizerTaxInformation.tin_digest_for(tax.tin))).to include(tax)
    expect(described_class::TIN_WARNING).to eq("This looks like a taxpayer ID. Remove it, or enter just the last 4 digits.")
  end
end
