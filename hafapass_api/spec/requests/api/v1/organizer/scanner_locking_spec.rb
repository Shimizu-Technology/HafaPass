# frozen_string_literal: true

require "rails_helper"
require "ostruct"
require "timeout"

RSpec.describe "Scanner download lock ordering", type: :request, webmock: true do
  self.use_transactional_tests = false

  before do
    raise "Scanner concurrency tests require test" unless Rails.env.test?

    clean_data
    allow(EmailService).to receive(:send_refund_notification_async)
    allow(StripeService).to receive(:verify_payment_context!).and_return(true)
    allow(Stripe::StripeClient).to receive(:new).and_raise("NO PROVIDER CLIENTS ALLOWED")
    @event = create(:event, :published, starts_at: 1.day.from_now)
    @staff = create(:user)
    @membership = create(:organization_membership, organization: @event.organization, user: @staff, role: :scanner,
      expires_at: 4.hours.from_now)
    @assignment = create(:event_staff_assignment, event: @event, user: @staff, role: :scanner, expires_at: 3.hours.from_now)
    @headers = auth_headers(@staff).merge("X-Organization-Id" => @event.organization_id.to_s)
    @base = "/api/v1/organizer/events/#{@event.id}/scanner_devices"
    @device = Admissions::DeviceRegistrar.call(event: @event, user: @staff, identifier: "same-browser", name: "Gate")
    @device.update!(authorization_expires_at: 30.minutes.from_now)
    @original_lease = @device.authorization_expires_at
  end

  after { clean_data }

  it "finishes manifest download, existing-ID renewal and external refund without a lock cycle" do
    type = create(:ticket_type, event: @event, quantity_sold: 2, quantity_available: 10)
    order = create(:order, event: @event)
    item = create(:order_item, order: order, ticket_type: type, quantity: 2,
      subtotal_cents: 5000, fee_cents: 250, organizer_proceeds_cents: 5000)
    payment = create(:payment, :succeeded, order: order)
    2.times { create(:ticket, order: order, order_item: item, ticket_type: type, event: @event) }
    operation = OpenStruct.new(id: "re_scanner_lock_race", status: "succeeded", amount: 5250,
      currency: "usd", payment_intent: payment.provider_payment_id)
    get "#{@base}/#{@device.id}/manifest", headers: @headers
    expect(response).to have_http_status(:ok)
    original_manifest = AdmissionManifest.find_by!(event: @event, version: response.parsed_body.dig("payload", "version"))
    original_payload = original_manifest.payload.deep_dup
    original_download = download_audits.sole
    original_evidence = original_download.after_data.deep_dup

    built, resume_download, event_locked, resume_renewal = Queue.new, Queue.new, Queue.new, Queue.new
    completed, outcomes, connections = Queue.new, Queue.new, Queue.new
    snapshot_evidence = Queue.new
    allow(Admissions::ManifestBuilder).to receive(:call).and_wrap_original do |original, **args|
      manifest = original.call(**args)
      if Thread.current[:scanner_worker] == :download
        built << true
        Timeout.timeout(8) { resume_download.pop }
      end
      manifest
    end
    allow_any_instance_of(Event).to receive(:lock!).and_wrap_original do |original, *args|
      result = original.call(*args)
      if Thread.current[:scanner_worker] == :renewal && !Thread.current[:paused_event]
        Thread.current[:paused_event] = true
        event_locked << true
        Timeout.timeout(8) { resume_renewal.pop }
      end
      result
    end
    allow(Admissions::HistoricalScanAuthority).to receive(:snapshot).and_wrap_original do |original, device|
      watermark = AuditLog.where(organization_id: device.organization_id).maximum(:id).to_i
      result = original.call(device)
      snapshot_evidence << [watermark, result] if Thread.current[:scanner_worker] == :download
      result
    end

    workers = []
    workers << worker(:download, outcomes, connections, completed) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.get "#{@base}/#{@device.id}/manifest", headers: @headers
      [client.response.status, client.response.parsed_body]
    end
    pids = { download: connections.pop.last }
    Timeout.timeout(8) { built.pop }
    workers << worker(:renewal, outcomes, connections, completed) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post @base, params: { identifier: @device.identifier, name: "Renewed gate" }, headers: @headers
      [client.response.status, client.response.parsed_body]
    end
    pids[:renewal] = connections.pop.last
    # Before the fix renewal owns EVENT; after the fix it waits for download's
    # ORG. Observe PostgreSQL rather than assuming thread scheduling or sleeping.
    await { event_locked.size.positive? || blocked_by?(pids[:renewal], pids[:download]) }
    workers << worker(:refund, outcomes, connections, completed) do
      refund = Commerce::ExternalRefundRecovery.ingest!(payment: Payment.find(payment.id), provider_refund: operation)
      [refund.status, refund.id]
    end
    pids[:refund] = connections.pop.last
    expect(pids.values.uniq.length).to eq(3)
    await do
      blocked_by?(pids[:refund], pids[:download]) || blocked_by?(pids[:refund], pids[:renewal])
    end
    resume_download << true
    # Old path: download now owns SCANNER and waits for refund's ORG. Releasing
    # renewal closes the three-way cycle. Fixed path: download can commit and
    # release its complete parent/scanner prefix before renewal proceeds.
    await { completed.size.positive? || blocked_by?(pids[:download], pids[:refund]) }
    resume_renewal << true
    Timeout.timeout(12) { workers.each(&:join) }
    results = 3.times.map { outcomes.pop }.to_h
    expect(results.values.grep(Exception)).to be_empty,
      results.transform_values { |value| value.is_a?(Exception) ? value.message : value.first }.inspect
    expect(results.fetch(:download).first).to eq(200)
    expect(results.fetch(:renewal)).to match([201, include("id" => @device.id, "name" => "Renewed gate")])
    expect(results.fetch(:refund).first).to eq("succeeded")

    downloaded = download_audits.order(:id).last!
    watermark, snapshot = snapshot_evidence.pop
    expect(downloaded.after_data.fetch("scan_authority")).to eq(snapshot.deep_stringify_keys.as_json)
    expect(snapshot.fetch(:audit_id)).to eq(watermark)
    expect(snapshot.fetch(:memberships)).to eq([grant_image(@membership)])
    expect(snapshot.fetch(:assignments)).to eq([grant_image(@assignment)])
    expect(downloaded.after_data.fetch("manifest_version")).to eq(original_manifest.version)
    expect(Time.iso8601(downloaded.after_data.fetch("lease_expires_at"))).to eq(@original_lease)
    expect(@device.reload.authorization_expires_at).to be > @original_lease
    expect(@device.last_manifest_digest).to eq(original_manifest.digest)
    expect(original_manifest.reload.payload).to eq(original_payload)
    expect(original_download.reload.after_data).to eq(original_evidence)
    expect(download_audits.count).to eq(2)
    expect(Admissions::HistoricalScanAuthority.new(device: @device, download: downloaded)
      .allowed?(at: Time.iso8601(snapshot.fetch(:captured_at)))).to be(true)

    2.times { Commerce::ExternalRefundRecovery.ingest!(payment: Payment.find(payment.id), provider_refund: operation) }
    expect(order.refunds.succeeded.count).to eq(1)
    refund = order.refunds.succeeded.sole
    expect(refund.refund_items.count).to eq(1)
    expect(refund.refund_items.sum(:amount_cents)).to eq(5250)
    expect(order.reload.refund_amount_cents).to eq(5250)
    expect(order.tickets).to all(be_cancelled)
    expect(type.reload.quantity_sold).to eq(0)
    expect(AuditLog.where(auditable: refund, action: "refund.succeeded").count).to eq(1)
  ensure
    workers&.each { |thread| thread.kill if thread.alive? }
    workers&.each(&:join)
  end

  %i[assignment_revoked device_revoked lease_expired].each do |change|
    it "refuses a download after waiting behind #{change}" do
      locked, release, outcomes, connections, completed = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
      workers = [worker(:mutation, outcomes, connections, completed) do
        @event.organization.with_lock do
          @event.lock!
          case change
          when :assignment_revoked then @assignment.update!(status: :revoked)
          when :device_revoked then ScannerDevice.find(@device.id).revoke!
          when :lease_expired then ScannerDevice.find(@device.id).update!(authorization_expires_at: 1.second.ago)
          end
          locked << true
          Timeout.timeout(8) { release.pop }
        end
        :committed
      end]
      mutation_pid = connections.pop.last
      Timeout.timeout(8) { locked.pop }
      workers << worker(:download, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.get "#{@base}/#{@device.id}/manifest", headers: @headers
        [client.response.status, client.response.parsed_body]
      end
      download_pid = connections.pop.last
      await { blocked_by?(download_pid, mutation_pid) }
      release << true
      Timeout.timeout(12) { workers.each(&:join) }
      results = 2.times.map { outcomes.pop }.to_h
      expect(results.fetch(:mutation)).to eq(:committed)
      expect(results.fetch(:download)).to match([403, include("error" => a_kind_of(String))])
      expect(@event.admission_manifests).to be_empty
      expect(download_audits).to be_empty
      expect(@device.reload.manifest_downloaded_at).to be_nil
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  it "rolls back the manifest and device evidence when the required snapshot audit fails" do
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "scanner_device.manifest_downloaded"))
      .and_raise(AuditLogger::WriteError, "synthetic audit failure")
    expect do
      get "#{@base}/#{@device.id}/manifest", headers: @headers
    end.to raise_error(AuditLogger::WriteError, "synthetic audit failure")
    expect(@event.admission_manifests).to be_empty
    expect(download_audits).to be_empty
    expect(@device.reload).to have_attributes(manifest_downloaded_at: nil, last_manifest_version: 0, last_manifest_digest: nil)
    allow(AuditLogger).to receive(:record!).and_call_original
    get "#{@base}/#{@device.id}/manifest", headers: @headers
    expect(response).to have_http_status(:ok)
    expect(download_audits.count).to eq(1)
    expect(@event.admission_manifests.count).to eq(1)
  end

  it "takes the organization lock before a direct model download update owns the scanner row" do
    locked, release, outcomes, connections, completed = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
    workers = [worker(:holder, outcomes, connections, completed) do
      Organization.find(@event.organization_id).with_lock do
        locked << true
        Timeout.timeout(8) { release.pop }
      end
      :released
    end]
    holder_pid = connections.pop.last
    Timeout.timeout(8) { locked.pop }
    workers << worker(:direct_download, outcomes, connections, completed) do
      ScannerDevice.find(@device.id).update!(manifest_downloaded_at: Time.current, last_manifest_version: 7)
    end
    writer_pid = connections.pop.last
    await { blocked_by?(writer_pid, holder_pid) }
    # This would raise LockWaitTimeout on the old callback path: its UPDATE
    # already owned SCANNER while its snapshot waited for ORG.
    ScannerDevice.transaction { ScannerDevice.lock("FOR UPDATE NOWAIT").find(@device.id) }
    release << true
    Timeout.timeout(12) { workers.each(&:join) }
    expect(2.times.map { outcomes.pop }.to_h).to eq(holder: :released, direct_download: true)
    expect(download_audits.sole.after_data).to include("manifest_version" => 7,
      "lease_expires_at" => @original_lease.iso8601(6))
  ensure
    workers&.each { |thread| thread.kill if thread.alive? }
    workers&.each(&:join)
  end

  def worker(name, outcomes, connections, completed)
    Thread.new do
      Thread.current[:scanner_worker] = name
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '4s'")
        connection.execute("SET statement_timeout = '6s'")
        connections << [name, connection.select_value("SELECT pg_backend_pid()").to_i]
        begin
          outcomes << [name, yield]
        rescue StandardError => error
          outcomes << [name, error]
        ensure
          completed << name
          connection.execute("RESET lock_timeout")
          connection.execute("RESET statement_timeout")
        end
      end
    end
  end

  def blocked_by?(waiting, holding)
    ActiveRecord::Base.connection.select_value("SELECT #{Integer(holding)} = ANY(pg_blocking_pids(#{Integer(waiting)}))")
  end

  def await
    Timeout.timeout(6) do
      loop do
        break if yield

        sleep 0.01
      end
    end
  end

  def download_audits
    AuditLog.where(auditable: @device, action: "scanner_device.manifest_downloaded")
  end

  def grant_image(row)
    { "id" => row.id, "role" => row.role, "status" => row.status, "expires_at" => row.expires_at.getutc.iso8601(6) }
  end

  def clean_data
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE audit_logs, audit_write_failures, users, organizer_profiles, events, site_settings, webhook_events RESTART IDENTITY CASCADE")
  end
end
