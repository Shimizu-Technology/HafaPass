require "rails_helper"
require "pdf/reader"

RSpec.describe "Organizer sales lists and exports", type: :request do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile, timezone: "Pacific/Guam") }
  let(:owner) { profile.user }
  let(:headers) { auth_headers(owner) }
  let(:base) { "/api/v1/organizer/events/#{event.id}" }
  let(:general) { create(:ticket_type, event: event, name: "General") }
  let(:vip) { create(:ticket_type, event: event, name: "VIP") }

  def sale(name:, type: general, source: nil, status: :issued, completed_at: Time.current, promo: nil)
    order = create(:order, event: event, buyer_name: "Buyer #{name}", buyer_email: "buyer-#{name.downcase}@example.test",
      completed_at: completed_at, source: source, promo_code: promo)
    item = create(:order_item, order: order, ticket_type: type)
    ticket = create(:ticket, event: event, order: order, order_item: item, ticket_type: type,
      attendee_name: name, holder_email: "#{name.downcase}@example.test", status: status)
    [order, ticket]
  end

  def names(filters = {})
    get "#{base}/attendees", params: filters, headers: headers
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("attendees").pluck("attendee_name")
  end

  it "applies ticket type, status, channel, promo, search, and pagination before counting" do
    promo = create(:promo_code, event: event, code: "ISLAND")
    first_order, first = sale(name: "Mina", type: vip, source: "box_office", status: :checked_in, promo: promo)
    sale(name: "Ana")
    expect(names(ticket_type: vip.id)).to eq(["Mina"])
    expect(names(status: "checked_in")).to eq(["Mina"])
    expect(names(channel: "box_office")).to eq(["Mina"])
    expect(names(promo_code: "island")).to eq(["Mina"])
    expect(names(search: first_order.reference)).to eq(["Mina"])
    expect(names(search: first.holder_email)).to eq(["Mina"])
    expect(names(sort: "name", direction: "asc", per_page: 1, page: 1)).to eq(["Ana"])
    expect(response.parsed_body.dig("meta", "total_count")).to eq(2)
    expect(names(sort: "name", direction: "asc", per_page: 1, page: 2)).to eq(["Mina"])
  end

  it "uses the event timezone for inclusive local dates and excludes test payments by default" do
    order, = sale(name: "Midnight", completed_at: Time.utc(2026, 10, 21, 14, 30))
    test_order, = sale(name: "Test")
    create(:payment, order: test_order, provider_environment: "test")
    expect(names(purchased_from: "2026-10-22", purchased_to: "2026-10-22")).to eq(["Midnight"])
    expect(names(payment_environment: "test")).to eq(["Test"])
    expect(names(payment_environment: "all")).to contain_exactly("Midnight", "Test")
    expect(order).to be_present
  end

  it "filters order view with the same query and sorts by amount" do
    sale(name: "Mina", type: vip)
    sale(name: "Ana")
    expect(names(view: "orders", ticket_type: vip.id)).to eq(["Buyer Mina"])
    expect(names(view: "orders", sort: "amount", direction: "asc")).to contain_exactly("Buyer Ana", "Buyer Mina")
  end

  it "supports the remaining status, channel, and sort choices" do
    paid, = sale(name: "Paid", source: "online", completed_at: 3.days.ago)
    refunded, = sale(name: "Refunded", source: "guest_list", completed_at: 2.days.ago)
    refunded.update!(status: :refunded)
    partial, = sale(name: "Partial", completed_at: 1.day.ago)
    partial.update!(status: :partially_refunded)
    _, cancelled = sale(name: "Cancelled", status: :cancelled)
    _, transferred = sale(name: "Transferred", status: :transferred)
    _, checked = sale(name: "Checked", status: :checked_in)
    checked.update!(checked_in_at: Time.current)
    expect(names(status: "paid")).to include("Paid")
    expect(names(status: "refunded")).to eq(["Refunded"])
    expect(names(status: "partially_refunded")).to eq(["Partial"])
    expect(names(status: "cancelled")).to eq(["Cancelled"])
    expect(names(status: "not_checked_in")).to include("Paid")
    expect(names(status: "not_checked_in")).not_to include("Checked", "Cancelled", "Transferred")
    expect(names(status: "transferred")).to eq(["Transferred"])
    expect(names(channel: "guest_list")).to eq(["Refunded"])
    expect(names(channel: "online")).to include("Paid")
    sale(name: "LegacyOnline", source: nil)
    expect(names(channel: "online")).to include("LegacyOnline")
    expect(names(sort: "purchase_date", direction: "asc").first).to eq("Paid")
    expect(names(sort: "check_in_time", direction: "desc").first).to eq("Checked")
    expect(names(sort: "ticket_type", direction: "asc")).to contain_exactly(
      "Paid", "Refunded", "Partial", "Cancelled", "Transferred", "Checked", "LegacyOnline")
    expect(cancelled).to be_cancelled
    expect(transferred).to be_transferred
    expect(paid).to be_completed
  end

  it "rejects invalid filters and does not expose customer rows to marketer roles" do
    sale(name: "Mina")
    get "#{base}/attendees", params: { purchased_from: "2026-99-99" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    get "#{base}/attendees", params: { sort: "orders.total_cents; DROP TABLE orders" }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    marketer = create(:user)
    create(:organization_membership, organization: event.organization, user: marketer, role: :marketer)
    get "#{base}/attendees", headers: auth_headers(marketer)
    expect(response).to have_http_status(:forbidden)
    post "#{base}/sales_exports", headers: auth_headers(marketer)
    expect(response).to have_http_status(:forbidden)
  end

  it "lets finance read order totals and excludes them from box office responses" do
    sale(name: "Mina")
    finance = create(:user)
    create(:organization_membership, organization: event.organization, user: finance, role: :finance)
    get "#{base}/attendees", params: { view: "orders" }, headers: auth_headers(finance)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("attendees").first).to include("amount_cents" => 5250)
    box = create(:user)
    create(:organization_membership, organization: event.organization, user: box, role: :box_office)
    create(:event_staff_assignment, event: event, user: box, role: :box_office)
    get "#{base}/attendees", params: { view: "orders" }, headers: auth_headers(box)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("attendees").first).not_to have_key("amount_cents")
  end

  it "guards columns by role and denies scanner exports" do
    sale(name: "Mina")
    box = create(:user)
    create(:organization_membership, organization: event.organization, user: box, role: :box_office)
    create(:event_staff_assignment, event: event, user: box, role: :box_office)
    post "#{base}/sales_exports", params: { columns: %w[name price_paid] }, headers: auth_headers(box)
    expect(response).to have_http_status(:unprocessable_entity)
    post "#{base}/sales_exports", params: { columns: %w[name email] }, headers: auth_headers(box)
    expect(response).to have_http_status(:ok)
    post "#{base}/sales_exports", params: { columns: %w[name phone] }, headers: auth_headers(box)
    expect(response).to have_http_status(:ok)
    manager = create(:user)
    create(:organization_membership, organization: event.organization, user: manager, role: :manager)
    post "#{base}/sales_exports", params: { columns: %w[name email price_paid] }, headers: auth_headers(manager)
    expect(response).to have_http_status(:ok)
    scanner = create(:user)
    create(:organization_membership, organization: event.organization, user: scanner, role: :scanner)
    create(:event_staff_assignment, event: event, user: scanner, role: :scanner)
    post "#{base}/sales_exports", params: { columns: %w[name email] }, headers: auth_headers(scanner)
    expect(response).to have_http_status(:forbidden)
  end

  it "exports exactly the filtered rows with BOM, safe formulas, and audit metadata" do
    sale(name: "=1+1", type: vip)
    sale(name: "Ana")
    post "#{base}/sales_exports", params: { ticket_type: vip.id, columns: %w[name order_number purchase_date] }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body.bytes.first(3)).to eq([239, 187, 191])
    records = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    expect(records.length).to eq(1)
    expect(records.first["Name"]).to eq("\t=1+1")
    expect(records.first["Purchase date"]).to include("ChST")
    audit = AuditLog.where(action: "sales.export_requested").last
    expect(audit.actor_user).to eq(owner)
    expect(audit.metadata).to include("row_count" => 1, "columns" => %w[name order_number purchase_date])
    expect(AuditLog.where(action: "sales.export_generated").last.metadata["outcome"]).to eq("generated")
    expect(AuditLog.where(action: "sales.export_downloaded").last.metadata["outcome"]).to eq("downloaded")
  end

  it "prints only filtered door rows with order numbers and audits the PDF" do
    order, = sale(name: "Mina")
    sale(name: "Ana", status: :cancelled)
    get "#{base}/sales_exports/door_list", params: { status: "issued" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(text).to include("Mina", order.reference, "Check in")
    expect(text).not_to include("Ana", "mina@example.test")
    expect(AuditLog.where(action: "sales.door_list_exported").last.metadata).to include("row_count" => 1)
  end

  it "summarizes check-in and accepted transfers on order-level CSV rows" do
    _order, ticket = sale(name: "Mina", status: :checked_in)
    ticket.update!(checked_in_at: Time.current)
    create(:ticket_transfer, ticket: ticket, status: :accepted, accepted_at: Time.current,
      recipient_email: "recipient@example.test")
    post "#{base}/sales_exports", params: { view: "orders", columns: %w[name check_in_time transferred_to] }, headers: headers
    expect(response).to have_http_status(:ok)
    record = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).first
    expect(record["Check-in time"]).to include("ChST")
    expect(record["Transferred to"]).to eq("recipient@example.test")
  end

  it "queues a large export and binds the download to its actor" do
    sale(name: "Mina")
    stub_const("Api::V1::Organizer::SalesExportsController::LARGE_EXPORT_THRESHOLD", 0)
    allow(S3Service).to receive(:configured?).and_return(true)
    expect { post "#{base}/sales_exports", params: { columns: %w[name] }, headers: headers }
      .to have_enqueued_job(OrganizerSalesExportJob)
    expect(response).to have_http_status(:accepted)
    export_request = OrganizerSalesExportRequest.last
    expect(export_request.row_count).to eq(1)
    other = create(:user)
    create(:organization_membership, organization: event.organization, user: other, role: :manager)
    get "#{base}/sales_exports/#{export_request.id}", headers: auth_headers(other)
    expect(response).to have_http_status(:not_found)
  end

  it "limits repeated exports for the same actor" do
    sale(name: "Mina")
    10.times do
      AuditLogger.record!(action: "sales.export_requested", auditable: event, actor: owner,
        metadata: { filters: {}, columns: %w[name], row_count: 1 })
    end
    post "#{base}/sales_exports", params: { columns: %w[name] }, headers: headers
    expect(response).to have_http_status(:too_many_requests)
  end

  it "writes a queued export in bounded batches and schedules private-file cleanup" do
    sale(name: "Mina")
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: { "view" => "tickets" }, columns: %w[name email], row_count: 1)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:put_object) do |options|
      content = options.fetch(:body).read
      expect(content.bytes.first(3)).to eq([239, 187, 191])
      expect(content).to include("Mina")
      expect(options.fetch(:acl)).to eq("private")
    end
    expect { OrganizerSalesExportJob.perform_now(request_record.id) }
      .to have_enqueued_job(OrganizerSalesExportCleanupJob)
    expect(request_record.reload).to have_attributes(status: "ready", row_count: 1)
    expect(request_record.storage_key).to start_with("private/sales-exports/")
    expect(AuditLog.where(action: "sales.export_generated").last.metadata).to include("row_count" => 1)
  end

  it "deletes an expired private export before removing its download key" do
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], row_count: 1, status: "ready",
      storage_key: "private/sales-exports/synthetic.csv", expires_at: 1.minute.ago)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    expect(client).to receive(:delete_object).with(bucket: "synthetic-sales-exports", key: request_record.storage_key)
    OrganizerSalesExportCleanupJob.perform_now(request_record.id)
    expect(request_record.reload).to have_attributes(status: "expired", storage_key: nil)
  end

  it "removes an uploaded CSV if the export fails before completion" do
    sale(name: "Mina")
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: { "view" => "tickets" }, columns: %w[name], row_count: 1)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:put_object)
    expect(client).to receive(:delete_object).with(bucket: "synthetic-sales-exports", key: start_with("private/sales-exports/"))
    allow(AuditLogger).to receive(:record!).and_raise("synthetic audit failure")

    expect { OrganizerSalesExportJob.perform_now(request_record.id) }.to raise_error("synthetic audit failure")
    expect(request_record.reload).to have_attributes(status: "failed", storage_key: nil)
  end
  it "keeps finance-only exports to transaction columns across roles" do
    sale(name: "Mina")
    roles = { finance: { allowed: %w[order_number ticket_price discount fee tax total_paid channel status purchase_date],
      denied: %w[name email phone check_in_time transferred_to notes_custom_answers] },
      box_office: { allowed: %w[name email phone check_in_time transferred_to notes_custom_answers],
        denied: %w[ticket_price discount fee tax total_paid] },
      manager: { allowed: %w[name email phone check_in_time transferred_to notes_custom_answers ticket_price discount fee tax total_paid], denied: [] } }
    roles.each do |role, columns|
      user = create(:user)
      create(:organization_membership, organization: event.organization, user: user, role: role)
      create(:event_staff_assignment, event: event, user: user, role: :box_office) if role == :box_office
      post "#{base}/sales_exports", params: { columns: columns[:allowed] }, headers: auth_headers(user)
      expect(response).to have_http_status(:ok), "#{role} should export its allowed columns"
      columns[:denied].each do |column|
        post "#{base}/sales_exports", params: { columns: [column] }, headers: auth_headers(user)
        expect(response).to have_http_status(:unprocessable_entity), "#{role} should not export #{column}"
      end
    end
  end

  it "uses the production payment classification for simulated and legacy nonlive orders" do
    sale(name: "Live")
    simulated, = sale(name: "Simulated")
    create(:payment, order: simulated, provider_environment: "simulate")
    legacy, = sale(name: "LegacyTest")
    create(:payment, order: legacy, provider_environment: nil, provider_payload: { simulated: "true" })
    expect(names).to eq(["Live"])
    expect(names(payment_environment: "test")).to contain_exactly("Simulated", "LegacyTest")
    expect(names(payment_environment: "all")).to contain_exactly("Live", "Simulated", "LegacyTest")
    expect(Order.where(id: [simulated.id, legacy.id]).where.not(id: Payment.nonlive_stripe.select(:order_id))).to be_empty
  end

  it "allocates a one-cent discount and all ticket money without losing cents" do
    order = create(:order, event: event, subtotal_cents: 200, service_fee_cents: 3,
      discount_cents: 1, total_cents: 202)
    type = create(:ticket_type, event: event)
    item = create(:order_item, order: order, ticket_type: type, unit_price_cents: 100,
      quantity: 2, discount_cents: 1, fee_cents: 3, tax_cents: 0)
    2.times { |index| create(:ticket, event: event, order: order, order_item: item, ticket_type: type, attendee_name: "Guest #{index}") }
    post "#{base}/sales_exports", params: { columns: %w[ticket_price discount fee tax total_paid] }, headers: headers
    expect(response).to have_http_status(:ok)
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    expect(rows.sum { |row| (BigDecimal(row["Ticket price"]) * 100).to_i }).to eq(200)
    expect(rows.sum { |row| (BigDecimal(row["Discount"]) * 100).to_i }).to eq(1)
    expect(rows.sum { |row| (BigDecimal(row["Fee"]) * 100).to_i }).to eq(3)
    expect(rows.sum { |row| (BigDecimal(row["Total paid"]) * 100).to_i }).to eq(202)
  end

  it "uses one ticket status for screen, filter, and CSV after a partial refund" do
    order, ticket = sale(name: "Mina")
    order.update!(status: :partially_refunded)
    get "#{base}/attendees", headers: headers
    expect(response.parsed_body.dig("attendees", 0, "sales_status")).to eq("partially_refunded")
    expect(names(status: "partially_refunded")).to eq(["Mina"])
    post "#{base}/sales_exports", params: { columns: %w[status] }, headers: headers
    expect(CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).first["Status"]).to eq("partially_refunded")
    ticket.update!(status: :cancelled)
    expect(names(status: "partially_refunded")).to be_empty
    expect(names(status: "cancelled")).to eq(["Mina"])
  end

  it "lists only the actor's unexpired recent exports and keeps the response private" do
    mine = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "ready", expires_at: 1.hour.from_now)
    other = create(:user)
    OrganizerSalesExportRequest.create!(event: event, actor_user: other,
      filters: {}, columns: %w[name], status: "ready", expires_at: 1.hour.from_now)
    OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "ready", expires_at: 1.minute.ago)
    get "#{base}/sales_exports", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.parsed_body.fetch("exports").pluck("id")).to eq([mine.id])
  end

  it "audits a completed queued download with request and export IDs" do
    item = OrganizerSalesExportRequest.create!(event: event, actor_user: owner, filters: {}, columns: %w[name],
      status: "ready", expires_at: 1.hour.from_now, storage_key: "private/sales-exports/test.csv")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get_object).and_yield("csv data")
    get "#{base}/sales_exports/#{item.id}", headers: headers
    expect(response.body).to eq("csv data")
    audit = AuditLog.where(action: "sales.export_downloaded").last
    expect(audit).to have_attributes(actor_user: owner)
    expect(audit.request_id).to be_present
    expect(audit.metadata).to include("export_request_id" => item.id, "outcome" => "downloaded")
  end

  it "records a failed queued stream without a successful download audit" do
    item = OrganizerSalesExportRequest.create!(event: event, actor_user: owner, filters: {}, columns: %w[name],
      status: "ready", expires_at: 1.hour.from_now, storage_key: "private/sales-exports/test.csv")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:get_object).and_raise(Aws::S3::Errors::InternalError.new(nil, "synthetic"))
    expect { get "#{base}/sales_exports/#{item.id}", headers: headers; response.body }.to raise_error(Aws::S3::Errors::InternalError)
    expect(AuditLog.where(action: "sales.export_downloaded")).to be_empty
    failed = AuditLog.where(action: "sales.export_download_failed").last
    expect(failed.metadata).to include("export_request_id" => item.id, "outcome" => "stream_failed")
  end

  it "matches the sales-export throttle for trailing slash and format-suffixed door lists" do
    throttle = Rack::Attack.throttles.fetch("sales-exports/ip")
    ["/sales_exports", "/sales_exports/", "/sales_exports.csv",
      "/sales_exports/door_list", "/sales_exports/door_list.pdf", "/sales_exports/door_list.pdf/",
      "/admissions/door_list.pdf", "/admissions/door_list/"].each do |suffix|
      path = "#{base}#{suffix}"
      method = suffix.start_with?("/sales_exports") && !suffix.include?("door_list") ? "POST" : "GET"
      rack_request = Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => "203.0.113.1"))
      expect(throttle.block.call(rack_request)).to eq("203.0.113.1"), path
    end
  end
  it "rechecks attendee access before listing or downloading a queued PII export" do
    actor = create(:user)
    membership = create(:organization_membership, organization: event.organization, user: actor, role: :manager)
    item = OrganizerSalesExportRequest.create!(event: event, actor_user: actor, filters: {}, columns: %w[phone],
      status: "ready", expires_at: 1.hour.from_now, storage_key: "private/sales-exports/test.csv")
    membership.update!(role: :finance)
    get "#{base}/sales_exports", headers: auth_headers(actor)
    expect(response.parsed_body.fetch("exports")).to be_empty
    get "#{base}/sales_exports/#{item.id}", headers: auth_headers(actor)
    expect(response).to have_http_status(:forbidden)
    expect(AuditLog.where(action: "sales.export_downloaded")).to be_empty
  end
end
