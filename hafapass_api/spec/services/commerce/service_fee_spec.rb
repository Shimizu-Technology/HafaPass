# frozen_string_literal: true

require "rails_helper"

# serviceFeeParity.json is generated from this class and also checked by the
# frontend's hostPricing.test.js, so the host-page calculator, the advertised
# all-in prices and checkout all agree to the cent.
RSpec.describe Commerce::ServiceFee do
  fixture = JSON.parse(Rails.root.join("../hafapass_frontend/src/utils/__fixtures__/serviceFeeParity.json").read)

  fixture.fetch("cases").each do |example|
    it "charges #{example.slice('price_cents', 'quantity', 'service_fee_percent', 'service_fee_flat_cents', 'buyer_fee_percent')} at checkout as advertised" do
      SiteSetting.instance.update!(service_fee_percent: example.fetch("service_fee_percent").to_d,
        service_fee_flat_cents: example.fetch("service_fee_flat_cents"))
      buyer_percent = example.fetch("buyer_fee_percent")
      policy = { 100 => :buyer_pays, 0 => :organizer_absorbs }.fetch(buyer_percent, :split_fees)
      event = create(:event, :published, fee_policy: policy, buyer_fee_percent: buyer_percent)
      type = create(:ticket_type, event: event, price_cents: example.fetch("price_cents"), quantity_available: 50)

      quote = described_class.for_event(event, type.price_cents)
      quantity = example.fetch("quantity")
      expect(quote.platform_fee_cents * quantity).to eq(example.fetch("platform_fee_cents"))
      expect(quote.all_in_price_cents * quantity).to eq(example.fetch("all_in_total_cents"))

      order = Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: type.id, quantity: quantity }],
        buyer_email: "buyer@example.com", buyer_name: "Buyer", payment_required: false).order
      expect(order).to have_attributes(service_fee_cents: example.fetch("buyer_fee_cents"),
        total_cents: example.fetch("all_in_total_cents"))
      expect(order.service_fee_cents + order.organizer_fee_cents).to eq(example.fetch("platform_fee_cents"))
    end
  end
end
