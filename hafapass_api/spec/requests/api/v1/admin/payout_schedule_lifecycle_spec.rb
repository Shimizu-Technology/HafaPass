# frozen_string_literal: true

require "rails_helper"

# The Copa promise, end to end in admin, on a fictional event that ends on a
# Saturday in Guam (Jan 30, 2027): bank transfer within 2–3 business days,
# about 10% held for 30 days, a chargeback inside the window, then the release
# and a final statement. Every amount comes from the real settlement services.
RSpec.describe "Admin payout schedule lifecycle", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:admin_headers) { auth_headers(admin) }
  let(:profile) { create(:organizer_profile, :verified, business_name: "Fictional Grappling League") }
  let(:organization) { profile.organization.tap { |org| org.update!(name: "Fictional Grappling League") } }
  let(:organizer_headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:event) do
    create(:event, :published, organization: organization, organizer_profile: profile, title: "Island Open Exhibition",
      starts_at: guam(2027, 1, 30, 9), ends_at: guam(2027, 1, 30, 18), doors_open_at: guam(2027, 1, 30, 8))
  end
  let(:adult) { create(:ticket_type, event: event, name: "Adult spectator", price_cents: 1700, quantity_available: 500) }
  let(:child) { create(:ticket_type, event: event, name: "Child spectator", price_cents: 1200, quantity_available: 500) }

  def due_row(list = "transfers")
    get "/api/v1/admin/payout_schedule", headers: admin_headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch(list).find { |row| row.dig("event", "id") == event.id }
  end

  def statement(payout_id: nil)
    get "/api/v1/organizer/events/#{event.id}/finance/payout_statement", headers: organizer_headers,
      params: { payout_id: payout_id }.compact
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body
  end

  def request_and_record_transfer!(row, reference:)
    post "/api/v1/admin/payouts", headers: admin_headers.merge("Idempotency-Key" => "copa-#{reference}"),
      params: { settlement_id: row.dig("settlement", "id") }
    expect(response).to have_http_status(:created), response.body
    payout = Payout.find(response.parsed_body.fetch("id"))
    expect(payout).to have_attributes(provider: "manual", status: "processing",
      amount_cents: row.dig("settlement", "available_to_payout_cents"))
    expect(due_row).to include("next_step" => "record_transfer", "in_flight_payout" => include("id" => payout.id))
    # Finance sends the transfer at the bank, then records it.
    travel 2.hours
    patch "/api/v1/admin/payouts/#{payout.id}", headers: admin_headers, params: {
      status: "paid", provider_payout_id: reference,
      evidence: { reference: "bank-statement/#{reference}", confirmed_at: 1.minute.ago.iso8601,
        reason: "Matched #{payout.amount_cents} cents on the bank statement" }
    }
    expect(response).to have_http_status(:ok), response.body
    payout.reload
  end

  before do
    # Production's manual gateway: HåfaPass reserves the amount and finance
    # sends the transfer outside it.
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
  end

  it "holds 10%, sends the transfer on schedule, absorbs a chargeback in the window and closes final" do
    travel_to guam(2027, 1, 10, 12) do
      approved_bank_account!(organization, actor: profile.user, admin: admin, last_four: "4321")
      @adult_order, @adult_item, @adult_capture = record_card_sale!(event, ticket_type: adult, quantity: 10,
        buyer_fee_cents: 100, processing_fee_cents: 560)
      @child_order, @child_item, @child_capture = record_card_sale!(event, ticket_type: child, quantity: 4,
        buyer_fee_cents: 100, processing_fee_cents: 190)
      # Partial refund: two adult tickets, their buyer fees returned too.
      record_card_refund!(@adult_order, @adult_item, @adult_capture, proceeds_cents: 3400, fee_cents: 200, quantity: 2)
    end
    travel_to guam(2027, 1, 30, 10) do
      record_door_cash_sale!(event, ticket_type: adult, user: profile.user, quantity: 3)
      expect(statement).to include("status" => "sales_open", "status_label" => "Sales open")
      expect(due_row).to be_nil
    end

    # Saturday evening it ends; Sunday morning it is still published.
    travel_to guam(2027, 1, 31, 9) do
      row = due_row
      expect(row).to include("next_step" => "complete_event", "ended_on" => "2027-01-30",
        "transfer_earliest_on" => "2027-02-02", "transfer_due_on" => "2027-02-03", "due_state" => "due",
        "reserve_release_on" => "2027-03-01")
      expect(statement).to include("status" => "waiting_for_payout")
      event.update!(status: :completed)
    end

    first_payout = nil
    travel_to guam(2027, 2, 2, 9) do
      # Card proceeds: 10 × $17 + 4 × $12 = $218.00, less $34.00 refunded,
      # less $7.50 actual processing. Door cash ($51.00) stays with the club.
      row = due_row
      expect(row).to include("next_step" => "hold_reserve", "net_proceeds_cents" => 17_650,
        "suggested_reserve_cents" => 1765, "owed_cents" => 17_650, "due_on" => "2027-02-03")
      expect(row["actions"]).to include("hold_reserve", "finalize_statement")

      post "/api/v1/admin/payout_schedule/#{event.id}/reserve", headers: auth_headers(profile.user)
      expect(response).to have_http_status(:forbidden)
      post "/api/v1/admin/payout_schedule/#{event.id}/reserve", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body).to include("kind" => "reserve_hold", "amount_cents" => -1765)
      expect(response.parsed_body["reason"]).to include("10%", "held until 2027-03-01")
      post "/api/v1/admin/payout_schedule/#{event.id}/reserve", headers: admin_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("A reserve is already held for this event")

      expect(due_row).to include("next_step" => "finalize_statement", "reserve_held_cents" => 1765, "owed_cents" => 15_885)
      post "/api/v1/admin/payout_schedule/#{event.id}/finalize", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body).to include("version" => 1, "reserve_cents" => 1765, "available_to_payout_cents" => 15_885)

      row = due_row
      expect(row).to include("next_step" => "send_transfer")
      first_payout = request_and_record_transfer!(row, reference: "TRF-20270202-01")
      expect(due_row).to be_nil
      reserve = due_row("reserves")
      expect(reserve).to include("next_step" => "wait_for_reserve", "due_state" => "upcoming", "due_on" => "2027-03-01")

      held = statement
      expect(held).to include("status" => "reserve_held", "status_label" => "Paid — reserve held until Mar 1, 2027")
      expect(held["transfers"].sole).to include("status" => "paid", "bank_last4" => "4321",
        "reference" => "TRF-20270202-01", "sent_on" => "2027-02-02", "amount_cents" => 15_885)
      expect(held.to_json).not_to include("998877664321")
      expect_statement_to_reconcile(held, event)
    end

    # A buyer's bank takes back one child order inside the 30-day window.
    travel_to guam(2027, 2, 15, 9) do
      record_lost_chargeback!(@child_order, @child_capture)
      reserve = due_row("reserves")
      expect(reserve).to include("next_step" => "wait_for_reserve", "owed_cents" => -5200)
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("held until 2027-03-01")
      expect(statement).to include("status" => "reserve_held")
    end

    # Mar 1, 2027 is Guam History and Chamorro Heritage Day: the release is due,
    # and the remaining transfer is due by the third business day after.
    travel_to guam(2027, 3, 1, 9) do
      reserve = due_row("reserves")
      expect(reserve).to include("next_step" => "release_reserve", "due_state" => "due", "due_on" => "2027-03-01")
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body).to include("kind" => "reserve_release", "amount_cents" => 1765)

      row = due_row
      # $17.65 released less the $52.00 chargeback leaves the club owing $34.35.
      expect(row).to include("next_step" => "negative_balance", "owed_cents" => -3435)
      final = statement
      expect(final).to include("status" => "final")
      expect(final.dig("totals", "balance_remaining_cents")).to eq(-3435)
      expect(final["notes"].join).to include("you owe $34.35")
      expect_statement_to_reconcile(final, event)
    end

    # Per-payout view: the frozen version the first transfer was paid from.
    receipt = statement(payout_id: first_payout.id)
    expect(receipt["payout"]).to include("id" => first_payout.id, "bank_last4" => "4321",
      "version" => include("version" => 1, "reserve_held_cents" => 1765, "available_cents" => 15_885,
        "previously_sent_cents" => 0))
  end

  it "sends the released reserve less a smaller chargeback as a second transfer and ends final" do
    travel_to guam(2027, 1, 10, 12) do
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      record_card_sale!(event, ticket_type: adult, quantity: 20, processing_fee_cents: 1000)
      @order, _item, @capture = record_card_sale!(event, ticket_type: child, quantity: 1, processing_fee_cents: 50)
    end
    travel_to guam(2027, 2, 1, 9) do
      event.update!(status: :completed)
      post "/api/v1/admin/payout_schedule/#{event.id}/reserve", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
      post "/api/v1/admin/payout_schedule/#{event.id}/finalize", headers: admin_headers
      request_and_record_transfer!(due_row, reference: "TRF-A")
    end
    travel_to(guam(2027, 2, 20, 9)) { record_lost_chargeback!(@order, @capture) }
    travel_to guam(2027, 3, 2, 10) do
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
      row = due_row
      # Net $340 + $12 − $10.50 = $341.50; reserve $34.15; chargeback $13.00.
      expect(row).to include("next_step" => "finalize_statement", "owed_cents" => 3415 - 1300, "due_on" => "2027-03-04")
      post "/api/v1/admin/payout_schedule/#{event.id}/finalize", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
      second = request_and_record_transfer!(due_row, reference: "TRF-B")
      expect(second.amount_cents).to eq(2115)
      expect(due_row).to be_nil
      expect(due_row("reserves")).to be_nil
      final = statement
      expect(final).to include("status" => "final", "status_label" => "Final")
      expect(final["transfers"].pluck("reference")).to eq(%w[TRF-A TRF-B])
      expect(final["totals"]).to include("balance_remaining_cents" => 0, "reserve_held_cents" => 0,
        "reserve_released_cents" => 3415)
      expect_statement_to_reconcile(final, event)

      get "/api/v1/organizer/events/#{event.id}/finance/payout_statement_export", headers: organizer_headers
      expect(response).to have_http_status(:ok)
      csv = CSV.parse(response.body.delete_prefix("﻿"))
      expect(csv.first).to eq(%w[section line amount note])
      expect(csv).to include(["Chargeback reserve", "Reserve released", "34.15", a_string_including("Chargebacks")])
      expect(csv).to include(["Balance", "Balance remaining", "0.00", ""])
      expect(AuditLog.where(action: "finance.exported").last.metadata).to include("export" => "payout_statement")
    end
  end

  it "requires a reason to release a reserve early and refuses while a dispute is open" do
    travel_to guam(2027, 1, 10, 12) do
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      @order, _item, @capture = record_card_sale!(event, ticket_type: adult, quantity: 5)
    end
    travel_to guam(2027, 2, 1, 9) do
      event.update!(status: :completed)
      PayoutReserves.hold!(event: event, actor: admin)
      dispute = Dispute.create!(order: @order, payment: @capture, amount_cents: 1800, currency: "usd",
        provider_dispute_id: "dp_open_fixture", status: :open, opened_at: Time.current)
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers,
        params: { early_release_reason: "Organizer has a long trusted history" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Resolve pending refunds and open disputes")
      dispute.update!(status: :won, closed_at: Time.current)
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers, params: { early_release_reason: "short" }
      expect(response).to have_http_status(:unprocessable_entity)
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers,
        params: { early_release_reason: "Organizer has a long trusted history" }
      expect(response).to have_http_status(:created), response.body
      audit = AuditLog.where(action: "balance_adjustment.posted").order(:id).last
      expect(audit.metadata).to include("early" => true, "early_release_reason" => "Organizer has a long trusted history")
    end
  end
end
