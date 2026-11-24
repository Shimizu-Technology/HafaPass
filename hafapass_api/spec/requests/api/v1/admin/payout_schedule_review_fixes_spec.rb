# frozen_string_literal: true

require "rails_helper"

# Regressions from the independent review of PR #239 (head c3d57b30). Each
# example failed there.
RSpec.describe "Admin payout schedule review fixes", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:admin_headers) { auth_headers(admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:organizer_headers) { auth_headers(profile.user).merge("X-Organization-Id" => organization.id.to_s) }
  let(:event) do
    create(:event, :published, organization: organization, organizer_profile: profile,
      starts_at: guam(2027, 1, 30, 9), ends_at: guam(2027, 1, 30, 18))
  end
  let(:ticket_type) { create(:ticket_type, event: event, price_cents: 9900, quantity_available: 100) }

  before do
    allow(PayoutGateway).to receive(:submit) do |payout|
      PayoutGateway::Result.new(provider_payout_id: "manual_po_#{payout.id}", status: :processing)
    end
  end

  def due_row(list = "transfers", target = event)
    get "/api/v1/admin/payout_schedule", headers: admin_headers
    expect(response).to have_http_status(:ok), response.body
    response.parsed_body.fetch(list).find { |row| row.dig("event", "id") == target.id }
  end

  def sell_and_complete!
    travel_to(guam(2027, 1, 10, 12)) do
      approved_bank_account!(organization, actor: profile.user, admin: admin)
      @order, @item, @capture = record_card_sale!(event, ticket_type: ticket_type, quantity: 1, processing_fee_cents: 300,
        bearer: "platform")
    end
    event.update!(status: :completed)
  end

  def pay_first_transfer!(reference: "TRF-FIRST")
    settlement = Settlements::Finalizer.call(event: event, actor: admin)
    payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "first-#{reference}")
    travel 1.hour
    PayoutReconciler.call(payout: payout, actor: admin, status: "paid", provider_payout_id: reference,
      evidence: { reference: "bank/#{reference}", confirmed_at: 1.minute.ago.iso8601, reason: "Matched bank statement" })
    payout
  end

  # Finding 3: a hold could post after the whole first payout was committed.
  %i[pending processing held paid].each do |status|
    it "refuses to hold a reserve once a payout is #{status}" do
      sell_and_complete!
      travel_to(guam(2027, 2, 1, 9)) do
        settlement = Settlements::Finalizer.call(event: event, actor: admin)
        payout = PayoutCreator.call(settlement: settlement, actor: admin, idempotency_key: "committed-#{status}")
        expect(payout.amount_cents).to eq(9900)
        payout.update_columns(status: Payout.statuses[status], held_from_status: status == :held ? "processing" : nil)
        post "/api/v1/admin/payout_schedule/#{event.id}/reserve", headers: admin_headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body["error"]).to include("already has a payout requested or sent")
        expect(event.balance_adjustments).to be_empty
        expect(due_row&.dig("actions").to_a).not_to include("hold_reserve")
      end
    end
  end

  # Finding 4: the agreed release date is stored on the hold and governs.
  it "keeps the release date agreed at hold time when the event is edited later" do
    sell_and_complete!
    travel_to(guam(2027, 2, 1, 9)) do
      hold = PayoutReserves.hold!(event: event, actor: admin)
      expect(hold.reserve_release_on).to eq(Date.new(2027, 3, 1))
      pay_first_transfer!
    end
    # The event's end time is corrected three weeks later after the fact.
    event.update_columns(ends_at: guam(2027, 2, 20, 18), starts_at: guam(2027, 2, 20, 9))
    expect(PayoutSchedule.for(event).standard_release_on).to eq(Date.new(2027, 3, 22))
    posted_hold = BalanceAdjustment.find_by!(kind: "reserve_hold")
    expect(posted_hold.update(reserve_release_on: Date.new(2027, 4, 1))).to be(false)
    expect(posted_hold.reload.reserve_release_on).to eq(Date.new(2027, 3, 1))
    travel_to(guam(2027, 3, 1, 9)) do
      row = due_row("reserves")
      expect(row).to include("reserve_release_on" => "2027-03-01", "reserve_release_due" => true, "next_step" => "release_reserve")
      get "/api/v1/organizer/events/#{event.id}/finance/payout_statement", headers: organizer_headers
      expect(response.parsed_body.dig("schedule", "reserve_release_on")).to eq("2027-03-01")
      expect(response.parsed_body["status_label"]).to eq("Paid — reserve held until Mar 1, 2027")
      post "/api/v1/admin/payout_schedule/#{event.id}/release", headers: admin_headers
      expect(response).to have_http_status(:created), response.body
    end
  end

  # Finding 6: unpaid events must not age out of Due.
  it "keeps an unpaid event in Due long after the lookback window" do
    old = create(:event, :completed, organization: organization, organizer_profile: profile,
      starts_at: guam(2026, 3, 1, 9), ends_at: guam(2026, 3, 1, 18))
    travel_to(guam(2026, 2, 1, 12)) do
      record_card_sale!(old, ticket_type: create(:ticket_type, event: old, price_cents: 2500), quantity: 2,
        processing_fee_cents: 150)
    end
    travel_to(guam(2026, 11, 24, 9)) do
      row = due_row("transfers", old)
      expect(row).to include("next_step" => "hold_reserve", "due_state" => "overdue", "owed_cents" => 4850)
      archived = create(:event, :completed, organization: organization, organizer_profile: profile,
        starts_at: guam(2026, 3, 2, 9), ends_at: guam(2026, 3, 2, 18))
      archived.update_columns(status: Event.statuses[:archived])
      expect(due_row("transfers", archived)).to be_nil
    end
  end

  # Minor: "Finalize without reserve" is an explicit, audited decision.
  it "records who skipped the reserve and why, even when the statement was already finalized" do
    sell_and_complete!
    travel_to(guam(2027, 2, 1, 9)) do
      organizer_version = Settlements::Finalizer.call(event: event, actor: profile.user)
      expect(due_row).to include("next_step" => "hold_reserve")
      post "/api/v1/admin/payout_schedule/#{event.id}/finalize", headers: admin_headers, params: { skip_reserve: true }
      expect(response).to have_http_status(:unprocessable_entity)
      post "/api/v1/admin/payout_schedule/#{event.id}/finalize", headers: admin_headers,
        params: { skip_reserve: true, skip_reason: "Long-standing organizer, approved by Leon" }
      expect(response).to have_http_status(:created), response.body
      expect(response.parsed_body).to include("id" => organizer_version.id, "reserve_skipped" => true)
      audit = AuditLog.find_by!(action: "payout_reserve.skipped", auditable: event)
      expect(audit.actor_user).to eq(admin)
      expect(audit.metadata).to include("reason" => "Long-standing organizer, approved by Leon",
        "settlement_id" => organizer_version.id, "suggested_reserve_cents" => 990)
      expect(due_row).to include("next_step" => "send_transfer", "reserve_skipped" => true)
    end
  end

  # Minor: the remainder is due 3 business days after the actual release.
  it "dates the remainder from the actual release day and decides early release from the reserve's own date" do
    sell_and_complete!
    travel_to(guam(2027, 2, 1, 9)) do
      PayoutReserves.hold!(event: event, actor: admin)
      pay_first_transfer!
      expect(due_row("reserves")).to include("reserve_release_due" => false)
    end
    travel_to(guam(2027, 3, 2, 10)) do
      expect(due_row("reserves")).to include("reserve_release_due" => true)
      PayoutReserves.release!(event: event, actor: admin)
      expect(due_row).to include("next_step" => "finalize_statement", "due_on" => "2027-03-05",
        "reserve_released_on" => "2027-03-02")
    end
  end

  # Finding 1 (API side): the Due row offers what PayoutCreator would accept.
  it "caps the offered payout by the organization-wide balance" do
    sell_and_complete!
    travel_to(guam(2027, 2, 1, 9)) do
      PayoutReserves.hold!(event: event, actor: admin)
      Settlements::Finalizer.call(event: event, actor: admin)
      allow(OrganizationPayoutBalance).to receive(:available_cents).and_return(800)
      expect(due_row["settlement"]).to include("available_to_payout_cents" => 8910, "requestable_cents" => 800)
      post "/api/v1/admin/payouts", headers: admin_headers.merge("Idempotency-Key" => "capped"),
        params: { settlement_id: due_row.dig("settlement", "id") }
      expect(response.parsed_body).to include("amount_cents" => 800, "disbursement_cents" => 800, "status" => "processing")
    end
  end
end
