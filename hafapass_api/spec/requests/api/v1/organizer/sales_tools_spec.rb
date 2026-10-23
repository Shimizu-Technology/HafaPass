require "rails_helper"

RSpec.describe "Api::V1::Organizer sales tools", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:user) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:headers) { auth_headers(user) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }

  it "configures catalog items, registration, waivers, and promoters" do
    post "#{base}/catalog_items", params: { name: "Shirt", kind: "merchandise", price_cents: 2500,
      inventory_quantity: 20 }, headers: headers
    expect(response).to have_http_status(:created)

    post "#{base}/registration_questions", params: { prompt: "Shirt size", kind: "selection", required: true,
      options: %w[S M L] }, headers: headers
    expect(response).to have_http_status(:created)

    post "#{base}/event_waivers", params: { title: "Participation waiver", version: "1", body: "Terms" }, headers: headers
    expect(response).to have_http_status(:created)

    post "#{base}/promoters", params: { name: "Island Team", code: "ISLAND", commission_bps: 750 }, headers: headers
    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("net_commission_cents" => 0)
  end

  it "exports CRM records and queues a segmented campaign" do
    event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    type = create(:ticket_type, event: event)
    order = create(:order, event: event, marketing_opt_in: true)
    item = create(:order_item, order: order, ticket_type: type)
    create(:ticket, order: order, event: event, ticket_type: type, order_item: item, holder_email: "guest@example.com")

    get "#{base}/crm/export", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include("guest@example.com")

    post "#{base}/communication_campaigns", params: { name: "Reminder", subject: "Tonight", body: "See you soon",
      segment: { type: "all_attendees" } }, headers: headers
    campaign = CommunicationCampaign.find(response.parsed_body.fetch("id"))
    post "#{base}/communication_campaigns/#{campaign.id}/send_now", headers: headers

    expect(response).to have_http_status(:accepted)
    expect(campaign.reload.recipient_count).to eq(1)
    expect(campaign.message_deliveries.count).to eq(1)
  end

  it "returns audience counts only for editable campaigns" do
    draft = create(:communication_campaign, event: event, status: :draft)
    sent = create(:communication_campaign, event: event, status: :sent)
    get "#{base}/communication_campaigns", headers: headers

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body
    expect(payload).not_to have_key("audience")
    campaigns = payload.fetch("communication_campaigns").index_by { |row| row.fetch("id") }
    expect(campaigns.fetch(draft.id)).to have_key("audience")
    expect(campaigns.fetch(sent.id)).not_to have_key("audience")
  end

  it "neutralizes spreadsheet formulas while preserving original attendee values" do
    type = create(:ticket_type, event: event, name: "=HYPERLINK(\"https://example.invalid\")")
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    names = ["=1+1", "+SUM(1,2)", "-1+1", "@SUM(1,2)", "  =1+1", "\t=1+1", "\rDanger",
      "＝1+1", "＋1+1", "－1+1", "＠SUM(1,2)", "=1+2\";,=1+2", "Ordinary Name"]
    tickets = names.map do |name|
      create(:ticket, order: order, event: event, ticket_type: type, order_item: item,
        attendee_name: name, holder_email: "guest@example.com")
    end

    get "#{base}/crm/export", headers: headers
    expect(response).to have_http_status(:ok)
    records = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    protected_names = names.map { |name| name == "Ordinary Name" ? name : "\t#{name}" }
    expect(records.map { |record| record["name"] }).to eq(protected_names.reverse)
    expect(records.map { |record| record["ticket_type"] }).to all(start_with("\t="))
    expect(response.body).to include("\"\t=1+1\"", "\"\t=1+2\"\";,=1+2\"")
    # The protective tab is data: retain it through CSV parse/save/reopen.
    reopened = CSV.parse(CSV.generate { |csv| records.each { |record| csv << record.fields } })
    expect(reopened.map(&:first)).to eq(protected_names.reverse)
    expect(tickets.map { |ticket| ticket.reload.attendee_name }).to eq(names)
  end

  it "audits the number of CRM rows actually sent when an email is blank" do
    type = create(:ticket_type, event: event)
    order = create(:order, event: event)
    item = create(:order_item, order: order, ticket_type: type)
    create(:ticket, order: order, event: event, ticket_type: type, order_item: item,
      holder_email: "guest@example.com")
    blank = create(:ticket, order: order, event: event, ticket_type: type, order_item: item)
    blank.update_column(:holder_email, "")

    get "#{base}/crm/export", headers: headers

    expect(response).to have_http_status(:ok)
    expect(CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).length).to eq(1)
    expect(AuditLog.where(action: "sales.exported").last.metadata).to include("row_count" => 1)
  end

  it "does not accumulate scheduled jobs for content-only campaign edits" do
    scheduled_at = 2.days.from_now

    expect {
      post "#{base}/communication_campaigns", params: { name: "Reminder", subject: "Tonight", body: "See you soon",
        scheduled_at: scheduled_at.iso8601, segment: { type: "all_attendees" } }, headers: headers
    }.to have_enqueued_job(CommunicationCampaignJob).once

    campaign = CommunicationCampaign.find(response.parsed_body.fetch("id"))
    expect {
      patch "#{base}/communication_campaigns/#{campaign.id}", params: { subject: "Updated reminder" }, headers: headers
    }.not_to have_enqueued_job(CommunicationCampaignJob)

    expect(response).to have_http_status(:ok)
    expect(campaign.reload).to be_scheduled
    expect(campaign.subject).to eq("Updated reminder")
  end

  it "isolates another organizer's event" do
    other = create(:organizer_profile)
    get "/api/v1/organizer/events/#{create(:event, organizer_profile: other).id}/catalog_items", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "records physical item fulfillment separately from the immutable order ledger" do
    type = create(:ticket_type, event: event)
    catalog = create(:catalog_item, event: event, kind: :merchandise)
    order = Commerce::OrderCreator.call(event: event,
      line_items: [{ ticket_type_id: type.id, quantity: 1 }],
      catalog_items: [{ catalog_item_id: catalog.id, quantity: 1 }],
      buyer_email: "buyer@example.com", buyer_name: "Buyer", payment_required: false).order
    item = order.order_items.item_merchandise.first

    post "#{base}/catalog_fulfillments/#{item.id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(item.catalog_fulfillment.reload).to be_fulfilled
    expect(item.reload.organizer_proceeds_cents).to eq(catalog.price_cents)
  end

  it "lets an authorized member review a failed campaign, save a draft, then reschedule it as themselves" do
    former = create(:user)
    campaign = create(:communication_campaign, event: event, status: :failed,
      scheduled_by_user: former, scheduled_at: 1.minute.ago, last_error: "Sender lost permission")
    patch "#{base}/communication_campaigns/#{campaign.id}", params: { subject: "Reviewed message", scheduled_at: nil },
      headers: headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(campaign.reload).to have_attributes(status: "draft", subject: "Reviewed message", last_error: nil)
    expect(campaign.message_deliveries).to be_empty

    expect do
      patch "#{base}/communication_campaigns/#{campaign.id}", params: { scheduled_at: 2.days.from_now.iso8601 }, headers: headers
    end.to have_enqueued_job(CommunicationCampaignJob).once
    expect(response).to have_http_status(:ok)
    expect(campaign.reload).to have_attributes(status: "scheduled", scheduled_by_user_id: user.id)
  end

  it "recovers a failed future campaign even when the reviewed schedule is unchanged" do
    former = create(:user)
    campaign = create(:communication_campaign, event: event, status: :failed,
      scheduled_by_user: former, scheduled_at: 2.days.from_now, last_error: "Sender lost permission")
    expect do
      patch "#{base}/communication_campaigns/#{campaign.id}", params: { subject: "Reviewed", scheduled_at: campaign.scheduled_at.iso8601(6) }, headers: headers
    end.to have_enqueued_job(CommunicationCampaignJob).once
    expect(response).to have_http_status(:ok)
    expect(campaign.reload).to have_attributes(status: "scheduled", scheduled_by_user_id: user.id, last_error: nil)
  end
  it "preserves a failed campaign's durable payload while allowing an authorized scheduling recovery" do
    campaign = create(:communication_campaign, event: event, status: :failed, started_at: 1.hour.ago,
      last_error: CommunicationCampaign::AUTHORIZATION_ERROR)
    patch "#{base}/communication_campaigns/#{campaign.id}", params: { subject: "Different message" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.fetch("error")).to include("Create a new campaign")
    expect(campaign.reload.subject).not_to eq("Different message")

    patch "#{base}/communication_campaigns/#{campaign.id}", params: { scheduled_at: 2.days.from_now.iso8601 }, headers: headers
    expect(response).to have_http_status(:ok), response.body
    expect(campaign.reload).to have_attributes(status: "scheduled", scheduled_by_user_id: user.id, last_error: nil)
    expect(AuditLog.where(auditable: campaign, action: "campaign.recovered", actor_user: user)).to exist
  end

  it "rechecks editability after waiting for outbox preparation" do
    campaign = create(:communication_campaign, event: event, status: :failed)
    allow_any_instance_of(Organization).to receive(:lock!).and_wrap_original do |method, *args|
      campaign.update!(status: :sending, started_at: Time.current)
      method.call(*args)
    end
    patch "#{base}/communication_campaigns/#{campaign.id}", params: { subject: "Stale editor content" }, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(campaign.reload.subject).not_to eq("Stale editor content")
  end
end
