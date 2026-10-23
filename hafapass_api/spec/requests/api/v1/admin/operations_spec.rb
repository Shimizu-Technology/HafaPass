# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin operations screens", type: :request do
  let(:admin) { create(:user, :admin) }
  let(:headers) { auth_headers(admin) }
  let(:profile) { create(:organizer_profile, :verified) }
  let(:organization) { profile.organization }
  let(:event) { create(:event, :published, organizer_profile: profile) }

  describe "authorization" do
    let(:organizer) { profile.user }

    [
      [:get, "/api/v1/admin/payouts"],
      [:get, "/api/v1/admin/balance_adjustments"],
      [:get, "/api/v1/admin/disputes"],
      [:get, "/api/v1/admin/audit_logs"],
      [:post, "/api/v1/admin/events/:event_id/policy_hold"],
      [:delete, "/api/v1/admin/events/:event_id/policy_hold"]
    ].each do |verb, path|
      it "refuses #{verb.upcase} #{path} to organizers, support staff and attendees" do
        [organizer, create(:user, role: :support), create(:user)].each do |user|
          send(verb, path.sub(":event_id", event.id.to_s), params: { scope: "sales", reason: "Policy" },
            headers: auth_headers(user))
          expect(response).to have_http_status(:forbidden)
        end
        expect(event.reload.policy_hold?).to be(false)
      end
    end

    it "refuses anonymous requests" do
      get "/api/v1/admin/audit_logs"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "event policy holds" do
    let(:ticket_type) { create(:ticket_type, event: event, price_cents: 0, quantity_available: 10) }

    def place(params = { scope: "sales", reason: "Listing violates the prohibited-items policy" })
      post "/api/v1/admin/events/#{event.id}/policy_hold", params: params, headers: headers
    end

    it "requires a scope and a reason" do
      place(scope: "sales", reason: "  ")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("A reason is required")
      place(scope: "delete", reason: "Policy")
      expect(response).to have_http_status(:unprocessable_content)
      expect(event.reload.policy_hold?).to be(false)
      expect(AuditLog.where(auditable: event, action: "event.policy_hold_placed")).not_to exist
    end

    it "stops sales without changing status, deleting data or refunding, and audits the hold" do
      ticket_type
      paid = create(:order, event: event, status: :completed)
      create(:ticket, order: paid, event: event, ticket_type: ticket_type)
      expect(event.sales_open?).to be(true)

      place
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["policy_hold"]).to include("scope" => "sales", "placed_by" => admin.email)

      event.reload
      expect(event).to have_attributes(status: "published", policy_hold_by_user_id: admin.id)
      expect(event.sales_open?).to be(false)
      expect(Event.discoverable).not_to include(event)
      expect(Event.publicly_visible).to include(event)
      expect(paid.reload.status).to eq("completed")
      expect(paid.tickets.count).to eq(1)
      expect(Refund.count).to eq(0)
      audit = AuditLog.find_by!(auditable: event, action: "event.policy_hold_placed")
      expect(audit).to have_attributes(actor_user: admin, organization: organization)
      expect(audit.metadata).to eq("reason" => "Listing violates the prohibited-items policy")
      expect(audit.after_data).to include("policy_hold_scope" => "sales")

      expect {
        Commerce::OrderCreator.call(event: event, line_items: [{ ticket_type_id: ticket_type.id, quantity: 1 }],
          buyer_email: "buyer@example.com", buyer_name: "Buyer", payment_required: false, service_fee: false)
      }.to raise_error(Commerce::OrderCreator::CheckoutError, "This event is not currently on sale")
    end

    it "hides the event from public pages with the hidden scope" do
      place(scope: "hidden", reason: "Counterfeit tickets reported")
      expect(response).to have_http_status(:created)

      get "/api/v1/events/#{event.slug}"
      expect(response).to have_http_status(:not_found)
      expect(Event.publicly_visible).not_to include(event)
    end

    it "shows the organizer the hold and its reason, but not which admin placed it" do
      place
      get "/api/v1/organizer/events/#{event.id}", headers: auth_headers(profile.user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["policy_hold"]).to include("scope" => "sales",
        "reason" => "Listing violates the prohibited-items policy")
      expect(response.parsed_body["policy_hold"]).not_to have_key("placed_by")
    end

    it "cannot be lifted by the organizer's seating resume" do
      place
      organizer_headers = auth_headers(profile.user)
      post "/api/v1/organizer/events/#{event.id}/seating/suspend", headers: organizer_headers, params: { reason: "Venue evacuation" }
      expect(response).to have_http_status(:ok)
      post "/api/v1/organizer/events/#{event.id}/seating/resume", headers: organizer_headers
      expect(response).to have_http_status(:ok)

      expect(event.reload.sales_suspended_at).to be_nil
      expect(event.policy_hold?).to be(true)
      expect(event.sales_open?).to be(false)
    end

    it "refuses to copy or repeat a held event, which would drop the hold" do
      event.update!(recurrence_rule: "weekly")
      place
      organizer_headers = auth_headers(profile.user)

      post "/api/v1/organizer/events/#{event.id}/clone", headers: organizer_headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("policy hold", "cannot be copied")
      post "/api/v1/organizer/events/#{event.id}/generate_recurrences", headers: organizer_headers, params: { count: 2 }
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to include("cannot be repeated")
      expect(Event.where(organization: organization).count).to eq(1)
    end

    it "refuses to issue waitlist offers while held" do
      allow(EmailService).to receive(:send_waitlist_offer_async)
      entry = create(:waitlist_entry, event: event, ticket_type: ticket_type, quantity: 1)
      place

      post "/api/v1/organizer/events/#{event.id}/waitlist/#{entry.id}/offer", headers: auth_headers(profile.user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq("This event is not currently on sale")
      expect(entry.reload).to be_waiting
      expect(WaitlistOffer.count).to eq(0)
      expect(EmailService).not_to have_received(:send_waitlist_offer_async)
    end

    it "refuses a second hold and restores sales with an audited reason" do
      place
      place(scope: "hidden", reason: "Escalation")
      expect(response).to have_http_status(:unprocessable_content)

      delete "/api/v1/admin/events/#{event.id}/policy_hold", params: { reason: "" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
      expect(event.reload.policy_hold?).to be(true)

      delete "/api/v1/admin/events/#{event.id}/policy_hold", params: { reason: "Organizer removed the listing items" },
        headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["policy_hold"]).to be_nil
      expect(event.reload).to have_attributes(policy_hold_at: nil, policy_hold_scope: nil, policy_hold_reason: nil)
      expect(event.sales_open?).to be(true)
      lifted = AuditLog.find_by!(auditable: event, action: "event.policy_hold_lifted")
      expect(lifted.before_data).to include("policy_hold_scope" => "sales")
      expect(lifted.metadata).to eq("reason" => "Organizer removed the listing items")

      delete "/api/v1/admin/events/#{event.id}/policy_hold", params: { reason: "Again" }, headers: headers
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lists held events for admins" do
      other = create(:event, :published, organizer_profile: profile)
      place

      get "/api/v1/admin/events", params: { policy_hold: "true" }, headers: headers
      expect(response.parsed_body["events"].pluck("id")).to eq([event.id])
      get "/api/v1/admin/events", headers: headers
      records = response.parsed_body["events"].index_by { |record| record["id"] }
      expect(records[event.id]["policy_hold"]).to include("scope" => "sales")
      expect(records[other.id]["policy_hold"]).to be_nil
    end
  end

  describe "payouts" do
    let(:settlement) { create(:settlement, organization: organization, event: event) }
    let(:account) { create(:connected_account, organization: organization, provider: "manual", with_readiness_approval: false) }
    let!(:processing) do
      create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
        status: :processing, amount_cents: 4200, provider_payout_id: "manual_po_1", created_at: 1.hour.ago)
    end
    let!(:paid) do
      create(:payout, organization: organization, event: event, settlement: settlement, connected_account: account,
        status: :paid, amount_cents: 900, provider_payout_id: "bank_ref_9", created_at: 2.hours.ago)
    end
    let!(:elsewhere) { create(:payout, status: :pending) }

    it "lists payouts with their context, allowed outcomes and status counts" do
      get "/api/v1/admin/payouts", params: { event_id: event.id }, headers: headers

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["payouts"].pluck("id")).to eq([processing.id, paid.id])
      expect(body["payouts"].first).to include("amount_cents" => 4200, "status" => "processing",
        "allowed_outcomes" => %w[paid failed reversed], "conflict_audit_id" => nil)
      expect(body["payouts"].first["organization"]).to eq("id" => organization.id, "name" => organization.name)
      expect(body["payouts"].first["settlement"]).to eq("id" => settlement.id, "version" => settlement.version)
      expect(body["payouts"].second["allowed_outcomes"]).to eq(%w[reversed])
      expect(body["status_counts"]).to include("processing" => 1, "paid" => 1, "pending" => 0)
      expect(body["meta"]).to include("total_count" => 2, "total_pages" => 1)
      expect(body["context"]["organization"]).to include("id" => organization.id, "name" => organization.name)
      expect(body["context"]["event"]).to include("id" => event.id)
    end

    it "filters by status and search text" do
      get "/api/v1/admin/payouts", params: { status: "pending" }, headers: headers
      expect(response.parsed_body["payouts"].pluck("id")).to eq([elsewhere.id])

      get "/api/v1/admin/payouts", params: { q: "bank_ref" }, headers: headers
      expect(response.parsed_body["payouts"].pluck("id")).to eq([paid.id])
    end

    it "shows the latest recorded reconciliation evidence" do
      patch "/api/v1/admin/payouts/#{processing.id}", headers: headers, params: {
        status: "failed", evidence: { reference: "bank-return-77", confirmed_at: 1.minute.ago.iso8601, reason: "Bank returned it" }
      }
      expect(response).to have_http_status(:ok)

      get "/api/v1/admin/payouts", params: { event_id: event.id, status: "failed" }, headers: headers
      record = response.parsed_body["payouts"].sole
      expect(record["allowed_outcomes"]).to eq([])
      expect(record["last_reconciliation"]).to include("recorded_by" => admin.email, "reference" => "bank-return-77",
        "reason" => "Bank returned it")
    end
  end

  describe "balance adjustments" do
    it "lists adjustments with who created them and whether they were reversed" do
      credit = create(:balance_adjustment, organization: organization, event: event, kind: "manual_credit", amount_cents: 500,
        created_by_user: admin)
      delete "/api/v1/admin/balance_adjustments/#{credit.id}", params: { reason: "Entered twice" }, headers: headers
      create(:balance_adjustment, kind: "manual_credit")

      get "/api/v1/admin/balance_adjustments", params: { organization_id: organization.id }, headers: headers

      expect(response).to have_http_status(:ok)
      records = response.parsed_body["balance_adjustments"]
      expect(records.pluck("kind")).to eq(%w[manual_debit manual_credit])
      original = records.find { |record| record["id"] == credit.id }
      expect(original).to include("status" => "reversed", "created_by" => admin.email)
      expect(original["reversed_by_id"]).to eq(records.first["id"])
      expect(original["event"]).to eq("id" => event.id, "title" => event.title)
    end

    it "only accepts the four manual kinds; the rest are posted by the system" do
      %w[dispute_loss dispute_recovery processing_fee payout_reversal bogus].each do |kind|
        post "/api/v1/admin/balance_adjustments", headers: headers,
          params: { organization_id: organization.id, kind: kind, amount_cents: -100, reason: "Fixture" }
        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(BalanceAdjustment.count).to eq(0)
    end

    it "reports a concurrent reversal as a conflict" do
      credit = create(:balance_adjustment, organization: organization, kind: "manual_credit", amount_cents: 500)
      # The other request's reversal committed after this one read the adjustment as posted.
      create(:balance_adjustment, organization: organization, kind: "manual_debit", amount_cents: -500, reversal_of: credit)

      delete "/api/v1/admin/balance_adjustments/#{credit.id}", params: { reason: "Entered twice" }, headers: headers

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["error"]).to eq("This adjustment was already reversed")
      expect(credit.reload).to be_status_posted
    end

    it "rejects a manual amount whose sign contradicts its kind" do
      {
        "manual_credit" => -500, "reserve_release" => -500, "manual_debit" => 500, "reserve_hold" => 500
      }.each do |kind, amount|
        post "/api/v1/admin/balance_adjustments", headers: headers,
          params: { organization_id: organization.id, event_id: event.id, kind: kind, amount_cents: amount, reason: "Fixture" }
        expect(response).to have_http_status(:unprocessable_content)
      end
      expect(BalanceAdjustment.count).to eq(0)

      post "/api/v1/admin/balance_adjustments", headers: headers,
        params: { organization_id: organization.id, event_id: event.id, kind: "reserve_hold", amount_cents: -500,
          reason: "Chargeback risk reserve" }
      expect(response).to have_http_status(:created)
      expect(AuditLog.find_by!(action: "balance_adjustment.posted").actor_user).to eq(admin)
    end
  end

  describe "disputes" do
    it "lists provider disputes with the order, event and organizer" do
      order = create(:order, event: event, buyer_email: "disputer@example.com", subtotal_cents: 5000, service_fee_cents: 350, total_cents: 5350)
      dispute = Dispute.create!(order: order, provider: "stripe", provider_dispute_id: "dp_123", amount_cents: 5350,
        currency: "usd", reason: "fraudulent", opened_at: 1.day.ago)
      Dispute.create!(order: create(:order), provider: "stripe", provider_dispute_id: "dp_456", amount_cents: 100,
        currency: "usd", status: :won, opened_at: 2.days.ago, closed_at: 1.day.ago)

      get "/api/v1/admin/disputes", params: { status: "open" }, headers: headers

      expect(response).to have_http_status(:ok)
      record = response.parsed_body["disputes"].sole
      expect(record).to include("id" => dispute.id, "status" => "open", "amount_cents" => 5350, "reason" => "fraudulent")
      expect(record["order"]).to include("id" => order.id, "buyer_email" => "disputer@example.com")
      expect(record["event"]).to include("id" => event.id, "title" => event.title)
      expect(record["organization"]).to eq("id" => organization.id, "name" => organization.name)
      expect(response.parsed_body["status_counts"]).to eq("open" => 1, "won" => 1, "lost" => 0)

      get "/api/v1/admin/disputes", params: { q: "##{order.id}" }, headers: headers
      expect(response.parsed_body["disputes"].pluck("id")).to eq([dispute.id])
    end
  end

  describe "audit logs" do
    it "returns a deleted actor's immutable identity without labeling it as system" do
      actor = create(:user)
      entry = AuditLogger.record!(action: "user.role_changed", auditable: actor, actor: actor)
      actor_id = actor.id
      actor.destroy!
      get "/api/v1/admin/audit_logs", params: { target_type: "User", target_id: actor_id }, headers: headers
      expect(response).to have_http_status(:ok)
      record = response.parsed_body["audit_logs"].find { |item| item["id"] == entry.id }
      expect(record).to include("actor_user_id" => actor_id, "actor" => nil)
    end

    it "searches and filters the append-only trail with pagination" do
      settings = SiteSetting.instance
      first = AuditLogger.record!(action: "site_settings.fee_terms_updated", auditable: settings, actor: admin,
        before_data: { "service_fee_percent" => "3.0" }, after_data: { "service_fee_percent" => "5.0" })
      AuditLogger.record!(action: "payout.reconciled", auditable: create(:payout), actor: create(:user, :admin))
      AuditLogger.record!(action: "balance_adjustment.posted",
        auditable: create(:balance_adjustment, organization: organization), organization: organization)

      get "/api/v1/admin/audit_logs", params: { q: admin.email }, headers: headers
      expect(response).to have_http_status(:ok)
      record = response.parsed_body["audit_logs"].sole
      expect(record).to include("id" => first.id, "action" => "site_settings.fee_terms_updated",
        "before_data" => { "service_fee_percent" => "3.0" }, "after_data" => { "service_fee_percent" => "5.0" })
      expect(record["actor"]).to include("email" => admin.email)
      expect(record["target"]).to eq("type" => "SiteSetting", "id" => settings.id)
      expect(record).not_to have_key("ip_address")
      expect(response.parsed_body["areas"]).to eq(%w[balance_adjustment event payout site_settings])

      get "/api/v1/admin/audit_logs", params: { area: "payout" }, headers: headers
      expect(response.parsed_body["audit_logs"].pluck("action")).to eq(["payout.reconciled"])

      get "/api/v1/admin/audit_logs", params: { organization_id: organization.id }, headers: headers
      expect(response.parsed_body["audit_logs"].pluck("action")).to eq(["balance_adjustment.posted"])

      get "/api/v1/admin/audit_logs", params: { from: 1.day.from_now.in_time_zone("Pacific/Guam").to_date.iso8601 }, headers: headers
      expect(response.parsed_body["audit_logs"]).to eq([])

      get "/api/v1/admin/audit_logs", params: { per_page: 2, page: 2 }, headers: headers
      expect(response.parsed_body["audit_logs"].pluck("id")).to eq(AuditLog.order(id: :desc).offset(2).limit(2).pluck(:id))
      expect(response.parsed_body["audit_logs"].pluck("id")).to include(first.id)
      expect(response.parsed_body["meta"]).to include("page" => 2, "total_count" => 4, "total_pages" => 2)
    end
  end

  describe "settings audit trail" do
    it "audits every change, and fee terms and payment mode under their own actions" do
      patch "/api/v1/admin/settings", params: { platform_email: "help@hafapass.test" }, headers: headers
      expect(response).to have_http_status(:ok)
      general = AuditLog.where(action: "site_settings.updated").sole
      expect(general).to have_attributes(actor_user: admin)
      expect(general.after_data).to eq("platform_email" => "help@hafapass.test")
      expect(AuditLog.where(action: %w[site_settings.fee_terms_updated site_settings.payment_mode_changed])).not_to exist

      PlatformCapabilityReviews::Manager.quick_approve!(capability: "policy_register", actor: admin)
      patch "/api/v1/admin/settings", params: { payment_mode: "simulate", service_fee_flat_cents: 75,
        effective_at: 31.days.from_now.iso8601, future_terms_approved: true,
        approved_registry_digest: FeeChange.proposed_registry_digest(settings: SiteSetting.instance,
          attributes: { service_fee_flat_cents: 75 }) }, headers: headers
      expect(AuditLog.where(action: "site_settings.updated").count).to eq(1)
      expect(AuditLog.find_by!(action: "site_settings.fee_terms_scheduled").after_data).to include("service_fee_flat_cents" => 75)
      expect(AuditLog.where(action: "site_settings.payment_mode_changed")).not_to exist

      allow(PaymentModeReadiness).to receive(:call).and_call_original
      allow(PaymentModeReadiness).to receive(:call).with("test").and_return({ mode: "test", ready: true, checks: [] })
      allow(StripeService).to receive(:verify_platform_credentials!).with("test").and_return(true)
      patch "/api/v1/admin/settings", params: { payment_mode: "test" }, headers: headers
      mode = AuditLog.find_by!(action: "site_settings.payment_mode_changed")
      expect([mode.before_data, mode.after_data]).to eq([{ "payment_mode" => "simulate" }, { "payment_mode" => "test" }])

      patch "/api/v1/admin/settings", params: { platform_email: "help@hafapass.test" }, headers: headers
      expect(AuditLog.where(action: "site_settings.updated").count).to eq(2)
    end
  end

  describe "dashboard platform revenue" do
    it "separates platform fees from processing for each bearer" do
      [["platform", 185], ["organizer", 185], [nil, 183]].each do |bearer, processing|
        order = create(:order, event: event, subtotal_cents: 5000, service_fee_cents: 350, total_cents: 5350,
          processing_fee_bearer_snapshot: bearer)
        create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000, fee_cents: 350,
          organizer_proceeds_cents: 5000)
        create(:fee_component, order: order, kind: "platform", amount_cents: 350)
        create(:fee_component, order: order, kind: "processing", amount_cents: processing, estimated: false,
          provider_reference: "txn_dash_#{SecureRandom.hex(4)}")
      end

      get "/api/v1/admin/dashboard", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["platform_revenue"]).to include("gross_platform_fee_cents" => 1050,
        "platform_processing_fee_cents" => 185, "organizer_processing_fee_cents" => 368,
        "net_platform_revenue_cents" => 865)
      expect(response.parsed_body).to include("open_disputes" => 0, "payouts_needing_reconciliation" => 0)
    end
  end
end
