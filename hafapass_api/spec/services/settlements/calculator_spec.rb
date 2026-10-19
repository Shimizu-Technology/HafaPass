require "rails_helper"

RSpec.describe Settlements::Calculator do
  it "calculates retained cash and multiple returns without querying each refund's order item" do
    profile = create(:organizer_profile, :verified)
    event = create(:event, :published, organizer_profile: profile)
    type = create(:ticket_type, event: event, price_cents: 1000, quantity_available: 10)
    allow(EmailService).to receive(:send_order_confirmation_async)
    allow(EmailService).to receive(:send_refund_notification_async)
    order = Commerce::CashSaleCreator.call(event: event, user: profile.user,
      parameters: { line_items: [{ ticket_type_id: type.id, quantity: 1 }], payment_method: "door_cash" },
      idempotency_key: "calculator-cash").order
    2.times do |index|
      Commerce::RefundCreator.call(order: order, amount_cents: 100, requested_by: profile.user,
        reason: "Cash already returned", idempotency_key: "calculator-return-#{index}",
        cash_return: { reference: "Drawer return #{index}", returned_at: Time.current.utc.iso8601(6) })
    end
    queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| queries << args.last[:sql] }
    result = described_class.call(event)
    expect(result.attributes).to include(organizer_proceeds_cents: 800, adjustment_cents: -800, payable_cents: 0)
    returns = result.items.select { |item| item[:metadata][:adjustment_kind] == "organizer_cash_return" }
    expect(returns.sum { |item| item[:amount_cents] }).to eq(200)
    expect(queries.grep(/FROM "order_items" WHERE "order_items"\."id" =/)).to be_empty
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "keeps the legacy platform fee description inside the settlement source digest" do
    # Settlement items are financial records: changing their text would change
    # source_digest for existing activity and force new settlement versions.
    event = create(:event, :published)
    order = create(:order, event: event)
    create(:fee_component, order: order, amount_cents: 250, kind: "platform")

    result = described_class.call(event)
    fee_item = result.items.find { |item| item[:kind] == "platform_fee" }
    canonical = result.items.map do |item|
      item.slice(:kind, :amount_cents, :currency, :source_type, :source_id, :description, :metadata)
    end

    expect(fee_item[:description]).to eq("Buyer-paid HafaPass service fee")
    expect(result.attributes[:source_digest]).to eq(Digest::SHA256.hexdigest(JSON.generate(canonical)))
  end
end
