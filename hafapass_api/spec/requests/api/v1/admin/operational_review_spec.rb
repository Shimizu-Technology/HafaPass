require "rails_helper"

RSpec.describe "Admin operational review", :webmock, type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { create(:user, :admin) }
  let(:path) { "/api/v1/admin/operations" }

  def receipt(**attributes)
    MessageProviderEvent.create!({ provider: "resend", provider_event_id: SecureRandom.uuid,
      provider_message_id: "private-provider-id", event_type: "email.delivered", occurred_at: 10.minutes.ago,
      received_at: 6.minutes.ago, payload: { "error" => { "message" => "private@example.invalid" } }
    }.merge(attributes))
  end

  def ids_for(category, page: 1)
    headers = auth_headers(admin)
    writes = []
    jobs = enqueued_jobs.dup
    subscriber = lambda do |*, payload|
      writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      get path, params: { category: category, page: page }, headers: headers
    end
    expect(writes).to be_empty
    expect(enqueued_jobs).to eq(jobs)
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("items").pluck("id")
  end

  it "serves retained external history only to admins and keeps dashboard warnings on the actionable count" do
    rows = Array.new(4) { receipt }
    unknown = receipt
    ExternalMessageReceipts.call(actor: admin, receipts: rows.map { |row| row.attributes.slice(*ExternalMessageReceipts::IDENTITY_KEYS) },
      proof_reference: "receipt-origin:admin-history-proof")
    expect(ids_for("external_message_receipts")).to eq(rows.map(&:id))
    expect(response.parsed_body.dig("history_counts", "external_message_receipts")).to eq(4)
    expect(response.parsed_body.dig("signals", "stale_message_events")).to eq(1)
    expect(response.body).not_to include("private-provider-id", "private@example.invalid", "admin-history-proof")
    expect(ids_for("stale_message_events")).to eq([unknown.id])
    get "/api/v1/admin/dashboard", headers: auth_headers(admin)
    expect(response.parsed_body.dig("operational_signals", "stale_message_events")).to eq(1)
    get path, params: { category: "external_message_receipts" }, headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
    expect(response.body).not_to include("external_confirmed", "private-provider-id")
  end

  it "uses exactly the dashboard scopes for stale, unlinked, linked, errored, fresh and processed receipts" do
    freeze_time do
      linked = create(:message_delivery, status: :sent)
      counted = [receipt(event_type: "email.sent"), receipt(event_type: "email.delivered"),
        receipt(message_delivery: linked), receipt(processing_error: "secret processing exception")]
      receipt(received_at: 5.minutes.ago) # strict older-than boundary
      receipt(received_at: 5.minutes.ago + 1.second)
      receipt(processed_at: Time.current)
      receipt(processed_at: Time.current, processing_error: "historic error")

      get "/api/v1/admin/dashboard", headers: auth_headers(admin)
      dashboard_signals = response.parsed_body.fetch("operational_signals")
      expect(dashboard_signals.fetch("stale_message_events")).to eq(4)
      expect(ids_for("stale_message_events")).to eq(counted.map(&:id))
      result = response.parsed_body
      expect(result.fetch("signals")).to eq(dashboard_signals)
      expect(result.fetch("meta")).to include("total_count" => 4, "total_pages" => 1)
      expect(result.fetch("items").pluck("review_state")).to eq(
        %w[no_linked_delivery no_linked_delivery awaiting_processing processing_error]
      )
      expect(result.fetch("items").last.fetch("processing_error")).to be(true)
      expect(result.fetch("items").first.keys).to contain_exactly(
        "id", "provider", "event_type", "received_at", "occurred_at", "delivery_id", "processing_error", "review_state"
      )
      expect(response.headers["Cache-Control"]).to eq("no-store")
      expect(response.body).not_to include("private@example.invalid", "private-provider-id", "secret processing", "payload")
    end
  end

  it "counts and lists the exact failed-message, payment, reconciliation and unknown-card records" do
    freeze_time do
      failed = create(:message_delivery, status: :failed, updated_at: 1.hour.ago)
      create(:message_delivery, status: :failed, updated_at: 1.hour.ago - 1.second)
      create(:message_delivery, status: :delivered)
      webhook = WebhookEvent.create!(provider: "stripe", provider_event_id: SecureRandom.uuid,
        event_type: "payment_intent.succeeded", status: :failed)
      WebhookEvent.create!(provider: "stripe", provider_event_id: SecureRandom.uuid, event_type: "other", status: :processed)
      exception = create(:reconciliation_exception)
      create(:reconciliation_exception, status: :resolved)
      order = create(:order)
      card = CardPresentPaymentAttempt.create!(organization: order.event.organization, event: order.event,
        order: order, payment: create(:payment, order: order), initiated_by_user: admin,
        card_present_account: create(:card_present_account, organization: order.event.organization),
        provider: "boh_clover", idempotency_key: SecureRandom.uuid, external_payment_id: SecureRandom.hex(8),
        amount_cents: 100, currency: "usd", initiated_at: Time.current, status: :result_unknown)
      expected = { "failed_messages_last_hour" => [failed.id], "failed_payment_webhooks" => [webhook.id],
        "open_reconciliation_exceptions" => [exception.id], "unknown_card_present_results" => [card.id] }
      get "/api/v1/admin/dashboard", headers: auth_headers(admin)
      signals = response.parsed_body.fetch("operational_signals")
      expected.each do |category, ids|
        expect(ids_for(category)).to eq(ids)
        expect(response.parsed_body.fetch("signals")).to eq(signals)
        expect(response.parsed_body.dig("meta", "total_count")).to eq(signals.fetch(category))
      end
      card.update!(status: :succeeded)
      expect(ids_for("unknown_card_present_results")).to be_empty
    end
  end

  it "paginates without dropping the full count and defaults to a nonempty category" do
    51.times { receipt }
    get path, headers: auth_headers(admin)
    expect(response.parsed_body.fetch("category")).to eq("stale_message_events")
    expect(response.parsed_body.dig("meta", "total_count")).to eq(51)
    first = response.parsed_body.fetch("items").pluck("id")
    expect(first.size).to eq(50)
    last = ids_for("stale_message_events", page: 2)
    expect(last.size).to eq(1)
    expect(first & last).to be_empty
  end

  it "returns an honest empty list and rejects invalid categories" do
    expect(ids_for("stale_message_events")).to be_empty
    expect(response.parsed_body.dig("meta", "total_count")).to eq(0)
    get path, params: { category: "payload" }, headers: auth_headers(admin)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "restricts provider-controlled vocabulary and never mutates records or queues work when read" do
    event = receipt(provider: "private-provider@example.invalid", event_type: "private-type@example.invalid",
      processing_error: "private-error@example.invalid")
    headers = auth_headers(admin)
    before = [event.reload.attributes, MessageDelivery.count, AuditLog.count, enqueued_jobs.dup, ActionMailer::Base.deliveries.dup]
    expect(MessageProviderEventProcessor).not_to receive(:call)
    expect(MessageProviderEventProcessor).not_to receive(:reconcile_for!)
    get path, headers: headers
    expect(response.parsed_body.fetch("items").first).to include("provider" => "other", "event_type" => "other")
    expect(response.body).not_to include("@example.invalid")
    expect([event.reload.attributes, MessageDelivery.count, AuditLog.count, enqueued_jobs, ActionMailer::Base.deliveries]).to eq(before)
  end

  [:support, :attendee, :organizer].each do |role|
    it "denies #{role} even with an organization header or category parameter" do
      get path, params: { category: "stale_message_events" },
        headers: auth_headers(create(:user, role: role)).merge("X-Organization-Id" => "1")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => "Admin access required")
    end
  end

  it "requires authentication and rechecks revoked admin authority" do
    get path
    expect(response).to have_http_status(:unauthorized)
    headers = auth_headers(admin)
    get path, headers: headers
    expect(response).to have_http_status(:ok)
    admin.update!(role: :support)
    get path, headers: headers
    expect(response).to have_http_status(:forbidden)
  end

  it "reports query unavailability without a false empty result or SQL details" do
    logged_errors = []
    allow(Rails.logger).to receive(:error) { |message| logged_errors << message }
    allow(OperationalReview).to receive(:new).and_raise(ActiveRecord::StatementInvalid, "private SQL")
    get path, headers: auth_headers(admin)
    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq("error" => "Operational review is temporarily unavailable")
    expect(logged_errors).to include({ event: "operational_review_failed",
      error_class: "ActiveRecord::StatementInvalid" }.to_json)
    expect(logged_errors.join).not_to include("private SQL")
  end
end
