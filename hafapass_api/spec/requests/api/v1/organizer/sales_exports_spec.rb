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
    mina, = sale(name: "Mina", type: vip)
    ana, = sale(name: "Ana")
    mina.update!(subtotal_cents: 5_750, total_cents: 6_000)
    ana.update!(subtotal_cents: 2_750, total_cents: 3_000)
    expect(names(view: "orders", ticket_type: vip.id)).to eq(["Buyer Mina"])
    expect(names(view: "orders", sort: "amount", direction: "asc")).to eq(["Buyer Ana", "Buyer Mina"])
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
    expect(response.parsed_body.fetch("attendees").first.keys).not_to include(
      "attendee_name", "attendee_email", "buyer_name", "buyer_email", "checked_in_at")
    get "#{base}/attendees", headers: auth_headers(finance)
    expect(response.parsed_body.fetch("attendees").first.keys).not_to include(
      "attendee_name", "attendee_email", "buyer_name", "buyer_email", "checked_in_at")
    box = create(:user)
    create(:organization_membership, organization: event.organization, user: box, role: :box_office)
    create(:event_staff_assignment, event: event, user: box, role: :box_office)
    get "#{base}/attendees", params: { view: "orders" }, headers: auth_headers(box)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("attendees").first).not_to have_key("amount_cents")
  end

  it "lets finance search order numbers without probing attendee names or emails" do
    order, ticket = sale(name: "Mina")
    finance = create(:user)
    create(:organization_membership, organization: event.organization, user: finance, role: :finance)
    [ticket.attendee_name, ticket.holder_email, order.buyer_name, order.buyer_email].each do |pii|
      get "#{base}/attendees", params: { search: pii }, headers: auth_headers(finance)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("attendees")).to be_empty
    end
    get "#{base}/attendees", params: { search: order.reference }, headers: auth_headers(finance)
    expect(response.parsed_body.fetch("attendees").pluck("order_number")).to eq([order.reference])
    get "#{base}/attendees", params: { sort: "name" }, headers: auth_headers(finance)
    expect(response).to have_http_status(:unprocessable_entity)
    post "#{base}/sales_exports", params: { sort: "name", columns: %w[order_number] }, headers: auth_headers(finance)
    expect(response).to have_http_status(:unprocessable_entity)
    post "#{base}/sales_exports", params: { search: ticket.holder_email, columns: %w[order_number] }, headers: auth_headers(finance)
    expect(response).to have_http_status(:ok)
    expect(CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)).to be_empty
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

  it "keeps a completed CSV valid when its completion audit fails" do
    sale(name: "Mina")
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "sales.export_generated"))
      .and_raise("synthetic audit failure")
    allow(Rails.logger).to receive(:error).and_call_original
    post "#{base}/sales_exports", params: { columns: %w[name] }, headers: headers
    expect(response.body).to include("Mina")
    expect(response.body).not_to include(SpreadsheetExport::INCOMPLETE_MARKER)
    expect(Rails.logger).to have_received(:error).with(/completion callback failed/)
  end

  it "marks a broken CSV incomplete even when its error audit also fails" do
    sale(name: "Mina")
    allow_any_instance_of(OrganizerSalesQuery).to receive(:each_batch).and_raise("synthetic row failure")
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "sales.export_failed"))
      .and_raise("synthetic audit failure")
    allow(Rails.logger).to receive(:error).and_call_original
    post "#{base}/sales_exports", params: { columns: %w[name] }, headers: headers
    expect(response.body).to include(SpreadsheetExport::INCOMPLETE_MARKER)
    expect(Rails.logger).to have_received(:error).with(/stopped early: RuntimeError: synthetic row failure/)
  end

  it "prints only filtered door rows with order numbers and audits the PDF" do
    order, = sale(name: "Mina")
    sale(name: "Ana", status: :cancelled)
    get "#{base}/sales_exports/door_list", params: { status: "issued" }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(text).to include("Mina", order.reference, "Check in", "Valid")
    expect(text).not_to include("Ana", "mina@example.test")
    expect(AuditLog.where(action: "sales.door_list_exported").last.metadata).to include("row_count" => 1)
    get "#{base}/sales_exports/door_list", headers: headers
    all_statuses = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(all_statuses).to include("Status", "Cancelled", "Ana")
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
      expect(options).not_to have_key(:acl)
    end
    expect { OrganizerSalesExportJob.perform_now(request_record.id) }
      .to have_enqueued_job(OrganizerSalesExportCleanupJob)
    expect(request_record.reload).to have_attributes(status: "ready", row_count: 1)
    expect(request_record.storage_key).to start_with("private/sales-exports/")
    expect(AuditLog.where(action: "sales.export_generated").last.metadata).to include("row_count" => 1)
  end

  it "claims a pending request only once" do
    sale(name: "Mina")
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], row_count: 1, status: "processing")
    expect(Aws::S3::Client).not_to receive(:new)
    OrganizerSalesExportJob.perform_now(request_record.id)
    expect(request_record.reload.status).to eq("processing")
  end

  it "reclaims an expired processing lease and completes the export" do
    sale(name: "Mina")
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], row_count: 1, status: "processing", claimed_at: 31.minutes.ago)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:put_object)
    OrganizerSalesExportJob.perform_now(request_record.id)
    expect(request_record.reload).to have_attributes(status: "ready", failure_reason: nil)
    expect(request_record.claimed_at).to be > 1.minute.ago
  end

  it "fails an expired lease in the download endpoint instead of polling forever" do
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "processing", claimed_at: 31.minutes.ago)
    get "#{base}/sales_exports/#{request_record.id}", headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include("status" => "failed", "error" => OrganizerSalesExportRequest::LEASE_FAILURE_REASON)
    expect(request_record.reload).to have_attributes(status: "failed", failure_reason: OrganizerSalesExportRequest::LEASE_FAILURE_REASON)
  end

  it "fails expired processing rows during the orphan sweep even without storage" do
    request_record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "processing", claimed_at: 31.minutes.ago)
    allow(S3Service).to receive(:configured?).and_return(false)
    OrganizerSalesExportOrphanSweepJob.perform_now
    expect(request_record.reload).to have_attributes(status: "failed", failure_reason: OrganizerSalesExportRequest::LEASE_FAILURE_REASON)
  end

  it "sweeps old unassociated uploads even when a request remains processing" do
    processing = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], row_count: 1, status: "processing")
    associated = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], row_count: 1, status: "ready",
      storage_key: "private/sales-exports/associated.csv", expires_at: 1.day.from_now)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    object = Struct.new(:key, :last_modified)
    page = Struct.new(:contents, :is_truncated, :next_continuation_token)
    allow(client).to receive(:list_objects_v2).and_return(page.new([
      object.new("private/sales-exports/orphan.csv", 3.days.ago),
      object.new(associated.storage_key, 3.days.ago),
      object.new("private/sales-exports/recent.csv", 1.hour.ago)
    ], false, nil))
    expect(client).to receive(:delete_object).once.with(bucket: "synthetic-sales-exports",
      key: "private/sales-exports/orphan.csv")
    OrganizerSalesExportOrphanSweepJob.perform_now
    expect(processing.reload.status).to eq("processing")
  end

  it "sweeps keys from expired requests after the grace period but keeps active and unexpired keys" do
    expired = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "ready",
      storage_key: "private/sales-exports/expired.csv", expires_at: 3.days.ago)
    active = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "processing",
      storage_key: "private/sales-exports/active.csv")
    unexpired = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], status: "ready",
      storage_key: "private/sales-exports/unexpired.csv", expires_at: 1.day.ago)
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    object = Struct.new(:key, :last_modified)
    page = Struct.new(:contents, :is_truncated, :next_continuation_token)
    allow(client).to receive(:list_objects_v2).and_return(page.new([
      object.new(expired.storage_key, 3.days.ago), object.new(active.storage_key, 3.days.ago),
      object.new(unexpired.storage_key, 3.days.ago),
      object.new("private/sales-exports/recent.csv", 1.hour.ago)
    ], false, nil))
    expect(client).to receive(:delete_object).once.with(bucket: "synthetic-sales-exports", key: expired.storage_key)
    OrganizerSalesExportOrphanSweepJob.perform_now
  end

  it "logs ListBucket denial and ends the sweep cleanly" do
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    allow(client).to receive(:list_objects_v2).and_raise(Aws::S3::Errors::AccessDenied.new(nil, "denied"))
    allow(Rails.logger).to receive(:error).and_call_original
    expect { OrganizerSalesExportOrphanSweepJob.perform_now }.not_to raise_error
    expect(Rails.logger).to have_received(:error).with(/Sales export orphan sweep: ListBucket permission/)
  end

  it "logs DeleteObject denial and continues to another orphan" do
    allow(S3Service).to receive(:configured?).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AWS_BUCKET").and_return("synthetic-sales-exports")
    client = instance_double(Aws::S3::Client)
    allow(Aws::S3::Client).to receive(:new).and_return(client)
    object = Struct.new(:key, :last_modified)
    page = Struct.new(:contents, :is_truncated, :next_continuation_token)
    allow(client).to receive(:list_objects_v2).and_return(page.new([
      object.new("private/sales-exports/first.csv", 3.days.ago),
      object.new("private/sales-exports/second.csv", 3.days.ago)
    ], false, nil))
    allow(client).to receive(:delete_object).with(bucket: "synthetic-sales-exports", key: "private/sales-exports/first.csv")
      .and_raise(Aws::S3::Errors::AccessDenied.new(nil, "denied"))
    expect(client).to receive(:delete_object).with(bucket: "synthetic-sales-exports", key: "private/sales-exports/second.csv")
    allow(Rails.logger).to receive(:error).and_call_original
    OrganizerSalesExportOrphanSweepJob.perform_now
    expect(Rails.logger).to have_received(:error).with(/Sales export orphan sweep: DeleteObject permission/)
  end

  it "enforces queued export status and nonnegative row counts in the database" do
    record = OrganizerSalesExportRequest.create!(event: event, actor_user: owner,
      filters: {}, columns: %w[name], row_count: 1)
    [{ status: "unknown" }, { row_count: -1 }].each do |attributes|
      expect do
        OrganizerSalesExportRequest.transaction(requires_new: true) { record.update_columns(attributes) }
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  it "keeps order tax export queries bounded per batch" do
    3.times { |index| sale(name: "Buyer#{index}") }
    query = OrganizerSalesQuery.new(event: event, params: { view: "orders" }, attendee_access: true)
    sql = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] unless payload[:cached]
    end
    begin
      OrganizerSalesExport.new(query: query, columns: %w[tax], finance: true, attendees: false).each_row.to_a
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
    expect(sql.grep(/SUM\(.*order_items.*tax_cents/i)).to be_empty
  end

  it "keeps the original ordered rows when a new sale arrives between export batches" do
    first, = sale(name: "First", completed_at: 3.days.ago)
    second, = sale(name: "Second", completed_at: 2.days.ago)
    third, = sale(name: "Third", completed_at: 1.day.ago)
    query = OrganizerSalesQuery.new(event: event, params: { view: "orders", sort: "purchase_date", direction: "desc" },
      attendee_access: true)
    batches = 0
    references = query.each_batch(size: 1, on_batch: ->(_batch) {
      batches += 1
      sale(name: "New", completed_at: Time.current) if batches == 1
    }).map(&:reference)
    expect(references).to eq([third, second, first].map(&:reference))
    expect(references.uniq.length).to eq(3)
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

  it "allocates legacy order cents across tickets without order items" do
    order = create(:order, event: event, subtotal_cents: 301, discount_cents: 1,
      service_fee_cents: 2, total_cents: 302)
    type = create(:ticket_type, event: event)
    3.times { |index| create(:ticket, event: event, order: order, order_item: nil,
      ticket_type: type, attendee_name: "Legacy #{index}") }
    post "#{base}/sales_exports", params: { columns: %w[ticket_price discount fee tax total_paid] }, headers: headers
    expect(response).to have_http_status(:ok)
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true)
    totals = { "Ticket price" => 301, "Discount" => 1, "Fee" => 2, "Tax" => 0, "Total paid" => 302 }
    totals.each do |column, cents|
      expect(rows.sum { |row| (BigDecimal(row[column]) * 100).to_i }).to eq(cents)
      expect(rows.map { |row| row[column] }).to all(be_present)
    end
  end

  it "allocates only residual cents to legacy tickets in a mixed order" do
    order = create(:order, event: event, subtotal_cents: 10_000, discount_cents: 100,
      service_fee_cents: 300, total_cents: 10_200)
    type = create(:ticket_type, event: event)
    item = create(:order_item, order: order, ticket_type: type, unit_price_cents: 5_000,
      quantity: 1, discount_cents: 40, fee_cents: 120)
    create(:ticket, event: event, order: order, order_item: item, ticket_type: type, attendee_name: "Item")
    create(:ticket, event: event, order: order, order_item: nil, ticket_type: type, attendee_name: "Legacy")
    post "#{base}/sales_exports", params: { columns: %w[name ticket_price discount fee tax total_paid] }, headers: headers
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).index_by { |row| row["Name"] }
    expect(rows["Item"]["Ticket price"]).to eq("50.00")
    expect(rows["Legacy"]["Ticket price"]).to eq("50.00")
    { "Ticket price" => 10_000, "Discount" => 100, "Fee" => 300, "Tax" => 0, "Total paid" => 10_200 }.each do |column, cents|
      expect(rows.values.sum { |row| (BigDecimal(row[column]) * 100).to_i }).to eq(cents)
    end
  end

  it "queries ticket groups once for all orders in a batch" do
    order = create(:order, event: event, subtotal_cents: 10_000, service_fee_cents: 0, total_cents: 10_000)
    type = create(:ticket_type, event: event)
    100.times { create(:ticket, event: event, order: order, ticket_type: type) }
    3.times { |index| sale(name: "Extra#{index}") }
    sql = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql << payload[:sql] unless payload[:cached]
    end
    begin
      query = OrganizerSalesQuery.new(event: event, params: {}, attendee_access: true)
      OrganizerSalesExport.new(query: query, columns: %w[ticket_price discount fee tax total_paid],
        finance: true, attendees: false).each_row.to_a
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
    expect(sql.grep(/SELECT "tickets"\."order_id", "tickets"\."id", "tickets"\."order_item_id" FROM "tickets"/i).length).to eq(1)
  end

  it "uses one ticket status for screen, filter, and CSV after a partial refund" do
    order, ticket = sale(name: "Mina")
    order.update!(status: :partially_refunded)
    get "#{base}/attendees", headers: headers
    expect(response.parsed_body.dig("attendees", 0, "sales_status")).to eq("partially_refunded")
    expect(response.parsed_body.dig("attendees", 0, "sales_status_label")).to eq("Partially refunded")
    expect(names(status: "partially_refunded")).to eq(["Mina"])
    post "#{base}/sales_exports", params: { columns: %w[status] }, headers: headers
    expect(CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).first["Status"]).to eq("Partially refunded")
    ticket.update!(status: :cancelled)
    expect(names(status: "partially_refunded")).to be_empty
    expect(names(status: "cancelled")).to eq(["Mina"])
  end

  it "shows cancelled-event refunds consistently on the list, filter, and CSV" do
    refunded_order, refunded_ticket = sale(name: "Refunded")
    pending_order, = sale(name: "Pending")
    event.update!(status: :cancelled)
    refunded_order.update!(status: :refunded)
    refunded_ticket.update!(status: :cancelled)

    expect(names(status: "refunded")).to eq(["Refunded"])
    expect(response.parsed_body.dig("attendees", 0, "sales_status_label")).to eq("Refunded")
    expect(names(status: "cancelled")).to eq(["Pending"])
    expect(names(status: "paid")).to be_empty
    post "#{base}/sales_exports", params: { columns: %w[name status] }, headers: headers
    expect(response).to have_http_status(:ok)
    rows = CSV.parse(response.body.delete_prefix("\uFEFF"), headers: true).to_a
    expect(rows).to include(["Refunded", "Refunded"], ["Pending", "Cancelled"])
    expect(pending_order).to be_completed
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

  it "separates higher-volume door-list throttling from export requests" do
    export_throttle = Rack::Attack.throttles.fetch("sales-exports/ip")
    door_throttle = Rack::Attack.throttles.fetch("door-lists/ip")
    expect(door_throttle.limit).to be > export_throttle.limit
    ["/sales_exports", "/sales_exports/", "/sales_exports.csv",
      "/sales_exports/door_list", "/sales_exports/door_list.pdf", "/sales_exports/door_list.pdf/",
      "/admissions/door_list.pdf", "/admissions/door_list/"].each do |suffix|
      path = "#{base}#{suffix}"
      method = suffix.start_with?("/sales_exports") && !suffix.include?("door_list") ? "POST" : "GET"
      rack_request = Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => "203.0.113.1"))
      matched = method == "POST" ? export_throttle : door_throttle
      expect(matched.block.call(rack_request)).to eq("203.0.113.1"), path
      expect((method == "POST" ? door_throttle : export_throttle).block.call(rack_request)).to be_nil
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
