# frozen_string_literal: true

require "rails_helper"
require "csv"

RSpec.describe "Activity audience security", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:owner) { profile.user }
  let(:event) { create(:event, organizer_profile: profile, title: "Reef Night") }
  let(:path) { "/api/v1/organizer/activity_logs" }

  def headers(person)
    auth_headers(person).merge("X-Organization-Id" => organization.id.to_s)
  end

  def member(role)
    create(:organization_membership, organization: organization, role: role).user
  end

  def record(action, subject: event, **attributes)
    AuditLogger.record!(action: action, auditable: subject, actor: owner, organization: organization, **attributes)
  end

  def csv(person, **filters)
    post "/api/v1/organizer/activity_log_exports", params: filters, headers: headers(person)
    expect(response).to have_http_status(:created)
    get response.parsed_body.dig("export", "download_url"), headers: headers(person)
    expect(response).to have_http_status(:ok)
    response.body
  end

  %i[manager finance owner event_manager].each do |role|
    it "projects door sale fields and sentences for #{role} in both JSON and CSV" do
      person = role == :owner ? owner : member(role == :event_manager ? :marketer : role)
      create(:event_staff_assignment, event: event, user: person, role: :manager) if role == :event_manager
      actions = %w[box_office.cash_sale_created card_present.payment_succeeded card_present.payment_failed card_present.payment_result_unknown]
      entries = actions.map do |action|
        record(action, before_data: { amount_cents: 12345, order_id: 987654321, status: "pending" },
          after_data: { amount_cents: 87654, order_id: 987654321, currency: "USD", ticket_count: 2, status: "paid" },
          metadata: { amount_cents: 87654, order_reference: "HP-PRIVATE-987", currency: "USD", lifecycle_result: "payment-private" })
      end
      get path, params: { area: "door" }, headers: headers(person)
      expect(response).to have_http_status(:ok)
      rows = response.parsed_body.fetch("activity_logs")
      expect(rows.pluck("id")).to match_array(entries.map(&:id))
      bodies = [response.body, csv(person, area: "door")]
      if %i[manager event_manager].include?(role)
        bodies.each do |body|
          expect(body).not_to include("87654", "876.54", "987654321", "HP-PRIVATE-987", "payment-private", "USD", "paid", "pending")
          expect(body).to include("John Doe recorded a door sale of 2 tickets for Reef Night.", "A card payment at the door failed.")
        end
        expect(rows.flat_map { |row| row["changes"] }.pluck("field")).to eq(["Ticket count"])
      else
        bodies.each { |body| expect(body).to include("$876.54", "HP-PRIVATE-987", "Amount cents") }
      end
      expect(entries.first.reload.metadata["order_reference"]).to eq("HP-PRIVATE-987")
    end
  end

  it "keeps event-staff history in event operations and organization security history Owner-only" do
    other_event = create(:event, organizer_profile: profile)
    mine = record("event_staff.assigned", metadata: { team_member_label: "Ana Cruz", team_role: "scanner" })
    other = record("event_staff.revoked", subject: other_event)
    owner_only = %w[organization.invitation_created organization.invitation_resent organization.invitation_accepted
      organization.membership_updated organization.membership_revoked organization.ownership_transferred
      organizer.verification_requested organizer.verification_updated connected_account.payout_details_updated
      connected_account.onboarding_started organizer_tax_information.updated tax_information.withholding_flag_changed]
      .map { |action| record(action, subject: organization) }
    assigned = member(:marketer)
    create(:event_staff_assignment, event: event, user: assigned, role: :manager)
    { owner => [mine, other, *owner_only], member(:manager) => [mine, other], assigned => [mine], member(:finance) => [] }.each do |person, visible|
      get path, headers: headers(person)
      rows = response.parsed_body.fetch("activity_logs")
      tested = [mine, other, *owner_only].map(&:id)
      expect(rows.pluck("id") & tested).to match_array(visible.map(&:id))
      expect(rows.find { |row| row["id"] == mine.id }&.fetch("area")).to eq("event_staff") if visible.include?(mine)
      activities = CSV.parse(csv(person).delete_prefix("\uFEFF"), headers: true).map { |row| row["Activity"] }
      owner_only.each do |entry|
        sentence = ActivityLogPresenter.new(entry, organization: organization).organization_json[:sentence]
        expect(activities.include?(sentence)).to eq(person == owner)
      end
    end
    get path, params: { area: "event_staff" }, headers: headers(assigned)
    expect(response.parsed_body.fetch("activity_logs").pluck("id") & [mine.id, other.id]).to eq([mine.id])
    get path, params: { area: "team" }, headers: headers(assigned)
    expect(response.parsed_body.fetch("activity_logs")).to be_empty
  end

  it "searches only rendered labels after event rename/removal and never hidden audience fields" do
    person = member(:manager)
    ticket = create(:ticket_type, event: event, name: "General Admission")
    entry = record("ticket_type.updated", subject: ticket, metadata: { event_title: "Old hidden event name" })
    event.update!(title: "Current visible name")
    get path, params: { q: "Old hidden event name" }, headers: headers(person)
    expect(response.parsed_body.fetch("activity_logs")).to be_empty
    get path, params: { q: "Current visible name" }, headers: headers(person)
    expect(response.parsed_body.fetch("activity_logs").pluck("id")).to include(entry.id)
    event.destroy!
    get path, params: { q: "Old hidden event name" }, headers: headers(person)
    expect(response.parsed_body.fetch("activity_logs")).to be_empty
    get path, params: { q: "General Admission" }, headers: headers(person)
    expect(response.parsed_body.fetch("activity_logs").pluck("id")).to include(entry.id)
    expect(csv(person, q: "Old hidden event name").lines.size).to eq(1)
  end

  it "does not match Finance-only money or order fields for a Manager in list or CSV" do
    person = member(:manager)
    finance = member(:finance)
    entry = record("box_office.cash_sale_created", metadata: { amount_cents: 87654, order_reference: "HP-PRIVATE-987" })
    ["876.54", "HP-PRIVATE-987"].each do |term|
      get path, params: { q: term }, headers: headers(person)
      expect(response.parsed_body.fetch("activity_logs")).to be_empty
      expect(csv(person, q: term).lines.size).to eq(1)
      [finance, owner].each do |viewer|
        get path, params: { q: term }, headers: headers(viewer)
        expect(response.parsed_body.fetch("activity_logs").pluck("id")).to eq([entry.id])
        expect(csv(viewer, q: term)).to include("$876.54", "HP-PRIVATE-987")
      end
    end
  end

  it "removes transaction references from other Manager operations while preserving configured prices" do
    person = member(:manager)
    %w[guest_list.updated waitlist_offer.converted catalog_fulfillment.fulfilled].each do |action|
      record(action, after_data: { order_id: 987654321, order_item_id: 987654322, unit_price_cents: 2500 })
    end
    record("ticket_type.updated", before_data: { price_cents: 2000 }, after_data: { price_cents: 2500 }, metadata: { subject_label: "General Admission" })
    get path, headers: headers(person)
    expect(response.body).not_to include("987654321", "987654322", "Order id", "Order item id")
    expect(response.body).to include("$20.00 to $25.00")
    expect(csv(person)).not_to include("987654321", "987654322", "Order id", "Order item id")
  end

  it "paginates rendered matches without dropping sparse matches between pages" do
    rows = 7.times.map { |i| record("ticket_type.updated", metadata: { subject_label: i.even? ? "Needle" : "Other" }) }
    found = []
    cursor = nil
    loop do
      get path, params: { q: "Needle", limit: 2, cursor: cursor }, headers: headers(owner)
      expect(response).to have_http_status(:ok)
      found += response.parsed_body.fetch("activity_logs").pluck("id")
      cursor = response.parsed_body.dig("meta", "next_cursor")
      break unless cursor
    end
    expect(found).to eq(rows.values_at(6, 4, 2, 0).map(&:id))
  end
end
