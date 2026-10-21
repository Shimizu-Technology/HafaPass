require "rails_helper"

RSpec.describe Payment, type: :model do
  describe "#card_summary" do
    it "accepts the existing provider key formats and validates each field" do
      payment = build(:payment, provider_payload: { "cardType" => "Visa", "last4" => "4242" })
      expect(payment.card_summary).to eq(brand: "Visa", last4: "4242")

      payment.provider_payload = { "card_brand" => "Master Card", "card_last4" => "1234" }
      expect(payment.card_summary).to eq(brand: "Master Card", last4: "1234")

      payment.provider_payload = { "cardType" => "<script>", "last4" => "12xx" }
      expect(payment.card_summary).to eq(brand: nil, last4: nil)
    end
  end
end
