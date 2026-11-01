require "rails_helper"

RSpec.describe "Api::V1::Support", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:support_user) { create(:user, role: :support) }
  let(:attendee) { create(:user, role: :attendee) }
  let(:order) { create(:order, reference: "HP-SUPPORT-123", buyer_email: "islandbuyer@example.com") }

  it "allows support to find operational records without financial configuration" do
    create(:ticket, order: order, event: order.event, ticket_type: create(:ticket_type, event: order.event))

    get "/api/v1/support/search", params: { q: "SUPPORT" }, headers: auth_headers(support_user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["orders"].first).to include("reference" => "HP-SUPPORT-123")
    expect(response.parsed_body.to_json).not_to include("provider_payment_id", "payout", "connected_account")
    expect(AuditLog.where(actor_user: support_user, action: "support.lookup")).to exist
  end

  it "denies the support console to an attendee" do
    get "/api/v1/support/search", params: { q: "SUPPORT" }, headers: auth_headers(attendee)

    expect(response).to have_http_status(:forbidden)
  end

  it "finds the printed ticket number without exposing admission credentials" do
    ticket = create(:ticket, order: order, event: order.event, ticket_type: create(:ticket_type, event: order.event))
    get "/api/v1/support/search", params: { q: "hp-t#{ticket.id}" }, headers: auth_headers(support_user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("tickets").map { |item| item.fetch("id") }).to eq([ticket.id])
    expect(response.parsed_body.to_json).not_to include(ticket.qr_code.to_s, ticket.scan_credential, ticket.display_credential)
  end

  it "treats an out-of-range printed number as an empty search" do
    get "/api/v1/support/search", params: { q: "HP-T999999999999999999999999" }, headers: auth_headers(support_user)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("tickets")).to be_empty
  end

  it "replays only failed delivery records and audits the actor" do
    delivery = create(:message_delivery, order: order, event: order.event, status: :failed)

    expect do
      post "/api/v1/support/message_deliveries/#{delivery.id}/resend", headers: auth_headers(support_user)
    end.to have_enqueued_job(MessageDeliveryJob).with(delivery.id)

    expect(response).to have_http_status(:accepted)
    expect(AuditLog.where(actor_user: support_user, action: "message_delivery.replayed", auditable: delivery)).to exist
  end

  describe "bulk re-send" do
    def bulk_resend(user: support_user, **params)
      post "/api/v1/support/message_deliveries/bulk_resend", params: params, headers: auth_headers(user), as: :json
    end

    def failed_delivery(**attributes)
      create(:message_delivery, order: order, event: order.event, status: :failed, failed_at: 1.hour.ago, **attributes)
    end

    it "queues retryable failed deliveries, skips unsafe ones by reason, and audits each replay" do
      queued = failed_delivery
      failed_delivery(provider_id: "re_accepted")
      failed_delivery(provider: "resend", attempts: 1, provider_outcome_unknown: true, provider_attempted_at: 2.days.ago)
      create(:message_delivery, order: order, recipient: "bounced@example.com", status: :bounced)
      failed_delivery(recipient: "bounced@example.com")
      create(:message_delivery, order: order, status: :sent)

      expect { bulk_resend(status: "failed") }.to have_enqueued_job(MessageDeliveryJob).with(queued.id).exactly(:once)

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body).to eq("queued" => 1, "matched" => 4, "capped" => false, "remaining" => 0,
        "skipped" => { "provider_accepted" => 1, "replay_window_expired" => 1, "suppressed_recipient" => 1 })
      audit = AuditLog.find_by!(action: "message_delivery.replayed", auditable: queued)
      expect(audit).to have_attributes(actor_user_id: support_user.id)
      expect(audit.metadata).to include("bulk" => true)
      expect(AuditLog.where(action: "message_delivery.replayed").count).to eq(1)
      expect(queued.reload.replay_requested_at).to be_present
    end

    it "filters by failure window and event" do
      in_window = failed_delivery(failed_at: 3.hours.ago)
      failed_delivery(failed_at: 30.hours.ago)
      failed_delivery(failed_at: 10.minutes.ago)
      other_event = create(:message_delivery, status: :failed, failed_at: 3.hours.ago)

      expect do
        bulk_resend(status: "failed", event_id: order.event_id, failed_after: 1.day.ago.iso8601, failed_before: 1.hour.ago.iso8601)
      end.to have_enqueued_job(MessageDeliveryJob).exactly(:once).with(in_window.id)
      expect(response.parsed_body).to include("queued" => 1, "matched" => 1)

      expect { bulk_resend(status: "failed", event_id: other_event.event_id) }
        .to have_enqueued_job(MessageDeliveryJob).exactly(:once).with(other_event.id)
    end

    it "caps one request, oldest failure first, and says more remain" do
      stub_const("Api::V1::Support::MessageDeliveriesController::BULK_RESEND_LIMIT", 2)
      oldest = failed_delivery(failed_at: 3.hours.ago)
      older = failed_delivery(failed_at: 2.hours.ago)
      failed_delivery(failed_at: 1.hour.ago)

      expect { bulk_resend(status: "failed") }.to have_enqueued_job(MessageDeliveryJob).exactly(:twice)
      expect(response.parsed_body).to include("queued" => 2, "matched" => 3, "capped" => true, "remaining" => 1)
      expect(AuditLog.where(action: "message_delivery.replayed").pluck(:auditable_id)).to contain_exactly(oldest.id, older.id)
    end

    it "queues the next batch when run again and never re-queues a replay from the last 15 minutes" do
      stub_const("Api::V1::Support::MessageDeliveriesController::BULK_RESEND_LIMIT", 2)
      oldest = failed_delivery(failed_at: 3.hours.ago)
      older = failed_delivery(failed_at: 2.hours.ago)
      newest = failed_delivery(failed_at: 1.hour.ago)

      expect { bulk_resend(status: "failed") }.to have_enqueued_job(MessageDeliveryJob).exactly(:twice)
      expect(response.parsed_body).to include("queued" => 2, "capped" => true)

      expect { bulk_resend(status: "failed") }.to have_enqueued_job(MessageDeliveryJob).exactly(:once).with(newest.id)
      expect(response.parsed_body).to include("queued" => 1, "capped" => false, "skipped" => { "recently_queued" => 2 })

      expect { bulk_resend(status: "failed") }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response.parsed_body).to include("queued" => 0, "capped" => false, "skipped" => { "recently_queued" => 3 })

      travel(16.minutes) do
        expect { bulk_resend(status: "failed") }.to have_enqueued_job(MessageDeliveryJob).exactly(:twice)
        expect(AuditLog.where(action: "message_delivery.replayed").order(:id).last(2).map(&:auditable_id))
          .to contain_exactly(oldest.id, older.id)
      end
    end

    it "skips a delivery just replayed on its own" do
      delivery = failed_delivery
      post "/api/v1/support/message_deliveries/#{delivery.id}/resend", headers: auth_headers(support_user)
      expect(delivery.reload.replay_requested_at).to be_present

      expect { bulk_resend(status: "failed") }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response.parsed_body).to include("queued" => 0, "skipped" => { "recently_queued" => 1 })
    end

    it "doesn't let suppressed recipients use up a batch" do
      stub_const("Api::V1::Support::MessageDeliveriesController::BULK_RESEND_LIMIT", 1)
      create(:message_delivery, order: order, recipient: "bounced@example.com", status: :bounced)
      failed_delivery(recipient: "bounced@example.com", failed_at: 3.hours.ago)
      deliverable = failed_delivery(failed_at: 2.hours.ago)

      expect { bulk_resend(status: "failed") }.to have_enqueued_job(MessageDeliveryJob).exactly(:once).with(deliverable.id)
      expect(response.parsed_body).to include("queued" => 1, "capped" => false, "skipped" => { "suppressed_recipient" => 1 })
    end

    it "examines at most the scan limit per request and reports what remains" do
      stub_const("Api::V1::Support::MessageDeliveriesController::BULK_RESEND_SCAN_LIMIT", 2)
      create(:message_delivery, order: order, recipient: "bounced@example.com", status: :bounced)
      failed_delivery(recipient: "bounced@example.com", failed_at: 4.hours.ago)
      failed_delivery(recipient: "BOUNCED@example.com ", failed_at: 3.hours.ago)
      unexamined = failed_delivery(failed_at: 2.hours.ago)

      expect { bulk_resend(status: "failed") }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response.parsed_body).to include("queued" => 0, "matched" => 3, "capped" => true, "remaining" => 1,
        "skipped" => { "suppressed_recipient" => 2 })
      expect(unexamined.reload.replay_requested_at).to be_nil
    end

    it "looks up suppressed recipients in a batch rather than once per row" do
      count_queries = lambda do
        count = 0
        counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A\s*(SAVEPOINT|RELEASE|ROLLBACK)/) }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { bulk_resend(status: "failed") }
        count
      end
      create(:message_delivery, order: order, recipient: "bounced@example.com", status: :bounced)
      2.times { failed_delivery(recipient: "bounced@example.com") }
      count_queries.call # warm per-user and per-process lookups
      few = count_queries.call
      expect(response.parsed_body["skipped"]).to eq("suppressed_recipient" => 2)

      %w[a b c d].each do |name|
        create(:message_delivery, order: order, recipient: "#{name}@bounced.example", status: :bounced)
        2.times { failed_delivery(recipient: "#{name}@bounced.example") }
      end
      expect(count_queries.call).to eq(few)
      expect(response.parsed_body["skipped"]).to eq("suppressed_recipient" => 10)
    end

    it "requires the failed status filter and valid times, and is limited to support staff" do
      failed_delivery
      expect { bulk_resend }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response).to have_http_status(:unprocessable_entity)
      expect { bulk_resend(status: "bounced") }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response).to have_http_status(:unprocessable_entity)
      expect { bulk_resend(status: "failed", failed_after: "yesterday", failed_before: "soon") }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("failed_after")
      expect { bulk_resend(status: "failed", user: attendee) }.not_to have_enqueued_job(MessageDeliveryJob)
      expect(response).to have_http_status(:forbidden)
    end
  end

  [:support, :admin].each do |role|
    it "keeps frozen email wire bytes and digest out of #{role} delivery responses" do
      payload = { "to" => "buyer@synthetic.invalid", "html" => "<a href='https://synthetic.invalid/?guest_token=private-fixture-link'>Order</a>" }
      body = JSON.generate(payload)
      digest = Digest::SHA256.hexdigest(body)
      delivery = create(:message_delivery, order: order, recipient: payload.fetch("to"), outbound_payload: payload,
        outbound_wire_body: body, wire_body_digest: digest)

      get "/api/v1/support/message_deliveries", headers: auth_headers(create(:user, role: role))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("deliveries").map { |item| item.fetch("id") }).to include(delivery.id)
      expect(response.body).not_to include("outbound_wire_body", "wire_body_digest", "private-fixture-link", digest)
    end
  end

  it "creates append-only support notes" do
    post "/api/v1/support/notes", params: { order_id: order.id, body: "Buyer confirmed the corrected address." },
      headers: auth_headers(support_user)

    expect(response).to have_http_status(:created)
    note = SupportNote.last
    expect(note.author_user).to eq(support_user)
    expect(note.update(body: "rewritten")).to be(false)
  end
end
