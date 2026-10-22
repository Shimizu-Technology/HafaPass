# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizerTaxInformation do
  it "does not trust legacy second-notice evidence without an identity digest" do
    tax = create(:organizer_tax_information, b_notice_stage: "second",
      b_notice_response_due_on: Date.yesterday, irs_validation_recorded_on: Date.current)
    expect(tax.validation_identity_digest).to be_nil
    expect(tax.irs_validation_current?).to be(false)
    expect(tax.backup_withholding_required?).to be(true)
    expect(tax.safe_json["irs_validation_recorded_on"]).to be_nil
  end

  it "encrypts the TIN at rest and round trips without exposing it in serialization or inspection" do
    tax = create(:organizer_tax_information)
    ciphertext = described_class.connection.select_value("SELECT tin FROM organizer_tax_informations WHERE id = #{tax.id}")
    expect(ciphertext).not_to include("012345678")
    expect(tax.reload.tin).to eq("012345678")
    expect(tax.tin_last_four).to eq("5678")
    expect(tax.as_json).to include("masked_tin" => "***-**-5678")
    expect(tax.as_json).not_to have_key("tin")
    expect(tax.inspect).not_to include("012345678")
  end

  it "serializes normal displays without decrypting the TIN" do
    tax = create(:organizer_tax_information).reload
    expect(tax).not_to receive(:tin)
    expect(tax.safe_json["masked_tin"]).to eq("***-**-5678")
  end

  it "validates identity, classification, TIN type, 9 digits and the certification record" do
    tax = build(:organizer_tax_information, legal_name: "", tax_classification: "other", tin_type: "itIN",
      tin: "123-45-6789", signer_name: "", certified_at: nil)
    expect(tax).not_to be_valid
    expect(tax.errors.attribute_names).to include(:legal_name, :tax_classification, :tin_type, :tin, :signer_name, :certified_at)
    expect(build(:organizer_tax_information, tin: "000000001", exempt_payee_code: "13")).to be_valid
    expect(build(:organizer_tax_information, exempt_payee_code: "14")).not_to be_valid
  end

  it "accepts all supported federal tax classifications" do
    described_class::CLASSIFICATIONS.each do |classification|
      expect(build(:organizer_tax_information, tax_classification: classification)).to be_valid
    end
  end

  it "requires tax information before a connected account can be payout ready" do
    account = create(:connected_account, with_tax_information: false)
    expect(account.active_payment_readiness_approval).to be_present
    expect(account).not_to be_payout_ready
    expect(account.organization).not_to be_payout_ready
    create(:organizer_tax_information, organization: account.organization)
    expect(account.reload).to be_payout_ready
    expect(account.organization.reload).to be_payout_ready
  end

  it "filters tax data from request logging" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
      .filter({ "tin" => "012345678", "tax_information" => { "tin" => "012345678" } })
    expect(filtered.values).to all(eq("[FILTERED]"))
  end
end
