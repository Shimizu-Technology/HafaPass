require "rails_helper"

RSpec.describe PilotCloseout do
  it "calculates the first-pilot conversion, abandonment, admission, and attribution baseline" do
    chain = create_live_pilot_run
    event = chain[:event]
    ticket_type = event.ticket_types.first
    order = create(:order, event: event, status: :completed, subtotal_cents: 0, service_fee_cents: 0,
      total_cents: 0)
    item = create(:order_item, order: order, ticket_type: ticket_type, unit_price_cents: 0,
      subtotal_cents: 0, fee_cents: 0, organizer_fee_cents: 0, organizer_proceeds_cents: 0)
    create(:ticket, order: order, order_item: item, event: event, ticket_type: ticket_type, status: :issued)
    MarketplaceFunnelEvent.create!(
      event: event, stage: :checkout_started, visitor_hash: "visitor-checkout", occurred_at: Time.current
    )
    MarketplaceFunnelEvent.create!(
      event: event, order: order, stage: :purchase, visitor_hash: "visitor-checkout", occurred_at: Time.current
    )
    event.update_columns(status: Event.statuses[:completed], updated_at: Time.current)
    record_safe_live_pilot_checkpoint(chain[:run])
    LivePilotRuns::Manager.complete!(
      run: chain[:run], actor: create(:user, :admin), attributes: valid_live_pilot_completion_attributes
    )

    metrics = described_class.local_metrics(chain[:run].reload)
    expect(metrics).to include(
      "completed_order_count" => 1, "checkout_conversion_bps" => 10_000,
      "checkout_abandonment_bps" => 0, "valid_ticket_count" => 1,
      "admitted_ticket_count" => 0, "no_show_rate_bps" => 10_000,
      "payout_variance_cents" => 0
    )
  end

  it "keeps box-office orders out of the online conversion denominator" do
    run = create_completed_live_pilot_run
    create(:order, event: run.event, status: :completed, source: "box_office", payment_method: "door_cash",
      subtotal_cents: 0, service_fee_cents: 0, total_cents: 0)
    MarketplaceFunnelEvent.create!(
      event: run.event, stage: :checkout_started, visitor_hash: "visitor-online", occurred_at: Time.current
    )

    metrics = described_class.local_metrics(run)

    expect(metrics).to include(
      "completed_order_count" => 1, "online_completed_order_count" => 0,
      "checkout_conversion_bps" => 0, "checkout_abandonment_bps" => 10_000
    )
  end
end
