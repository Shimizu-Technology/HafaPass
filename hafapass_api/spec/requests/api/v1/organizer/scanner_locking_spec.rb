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

  %i[sync recover].each do |operation|
    it "finishes manifest download, #{operation} and a same-actor staff mutation without a lock cycle" do
      @membership.update!(role: :manager)
      target = create(:user)
      create(:organization_membership, organization: @event.organization, user: target, role: :scanner)
      ticket = create(:ticket, event: @event, order: create(:order, event: @event),
        ticket_type: create(:ticket_type, event: @event))
      get "#{@base}/#{@device.id}/manifest", headers: @headers
      expect(response).to have_http_status(:ok)
      manifest = AdmissionManifest.find_by!(event: @event, version: response.parsed_body.dig("payload", "version"))
      original_payload = manifest.payload.deep_dup
      original_digest = manifest.digest
      original_download = download_audits.sole
      original_evidence = original_download.after_data.deep_dup
      input = { action_uuid: SecureRandom.uuid, sequence: 1, kind: "admit", source: "offline",
        ticket_id: ticket.id, credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential),
        manifest_version: manifest.version, occurred_at: Time.current.iso8601(6) }
      params = { actions: [input] }
      if operation == :recover
        params.merge!(reason: "Independently checked original gate journal",
          window_start: original_download.after_data.fetch("downloaded_at"), window_end: Time.current.iso8601(6))
      end

      download_ready, resume_download, actor_ready, resume_actor = Queue.new, Queue.new, Queue.new, Queue.new
      completed, outcomes, connections = Queue.new, Queue.new, Queue.new
      allow_any_instance_of(ScannerDevice).to receive(:lock!).and_wrap_original do |original, *args|
        if Thread.current[:scanner_worker] == :download && !Thread.current[:paused_device]
          Thread.current[:paused_device] = true
          download_ready << true
          Timeout.timeout(8) { resume_download.pop }
        end
        original.call(*args)
      end
      allow_any_instance_of(User).to receive(:lock!).and_wrap_original do |original, *args|
        if Thread.current[:scanner_worker] == :admission && !Thread.current[:paused_actor]
          Thread.current[:paused_actor] = true
          actor_ready << true
          Timeout.timeout(8) { resume_actor.pop }
        end
        original.call(*args)
      end
      workers = [worker(:download, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.get "#{@base}/#{@device.id}/manifest", headers: @headers
        [client.response.status, client.response.parsed_body]
      end]
      pids = { download: connections.pop.last }
      Timeout.timeout(8) { download_ready.pop } # A owns ORG/EVENT, before SCANNER.
      workers << worker(:admission, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post "#{@base}/#{@device.id}/#{operation}", params: params, headers: @headers
        [client.response.status, client.response.parsed_body]
      end
      pids[:admission] = connections.pop.last
      Timeout.timeout(8) { actor_ready.pop } # Old B owns SCANNER; fixed B owns no row yet.
      workers << worker(:staff, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post "/api/v1/organizer/events/#{@event.id}/staff_assignments",
          params: { user_id: target.id, role: "scanner" }, headers: @headers
        [client.response.status, client.response.parsed_body]
      end
      pids[:staff] = connections.pop.last
      expect(pids.values.uniq.size).to eq(3)
      await { blocked_by?(pids[:staff], pids[:download]) } # C owns ACTOR, waits for A's ORG.
      resume_actor << true
      await { blocked_by?(pids[:admission], pids[:staff]) } # B waits for C's ACTOR.
      resume_download << true # Old A waits for B's SCANNER, closing A -> B -> C -> A.
      Timeout.timeout(12) { workers.each(&:join) }
      results = 3.times.map { outcomes.pop }.to_h
      expect(results.values.grep(Exception)).to be_empty,
        results.transform_values { |value| value.is_a?(Exception) ? "#{value.class}: #{value.message}" : value.first }.inspect
      expect(results.fetch(:download).first).to eq(200)
      expect(results.fetch(:admission)).to match([200, include("results" => [include(
        "action_uuid" => input[:action_uuid], "sequence" => 1, "result" => "accepted", "reason_code" => "admitted")])])
      expect(results.fetch(:staff).first).to eq(201)
      assigned = @event.event_staff_assignments.find_by!(user: target, role: :scanner)
      expect(assigned).to be_status_active
      staff_audit = AuditLog.find_by!(auditable: assigned, action: "event_staff.assigned")
      expect(staff_audit).to have_attributes(actor_user_id: @staff.id, organization_id: @event.organization_id,
        event_id: @event.id)
      expect(staff_audit.after_data).to include("target_user_id" => target.id, "role" => "scanner", "status" => "active")
      expect(AdmissionAction.where(scanner_device: @device).count).to eq(1)
      expect(AdmissionAction.find_by!(action_uuid: input[:action_uuid])).to have_attributes(sequence: 1, ticket_id: ticket.id)
      expect(ticket.reload).to be_checked_in
      expect(@device.reload.last_sequence).to eq(1)
      expect(AuditLog.where(auditable: AdmissionAction.find_by!(action_uuid: input[:action_uuid]),
        action: "ticket.admission_reconciled").count).to eq(1)
      if operation == :recover
        expect(AuditLog.find_by!(auditable: @device, action: "scanner_device.journal_recovered").metadata)
          .to include("original_user_id" => @staff.id, "action_uuids" => [input[:action_uuid]])
      end
      expect(manifest.reload).to have_attributes(payload: original_payload, digest: original_digest)
      expect(original_download.reload.after_data).to eq(original_evidence)
      expect(@device.authorization_expires_at).to eq(@original_lease)
      expect(download_audits.count).to eq(2)
      latest = download_audits.order(:id).last!
      expect(latest.after_data).to include("manifest_version" => manifest.version,
        "lease_expires_at" => @original_lease.iso8601(6))
      snapshot = latest.after_data.fetch("scan_authority")
      expect(snapshot.fetch("memberships")).to eq([grant_image(@membership)])
      expect(snapshot.fetch("assignments")).to eq([grant_image(@assignment)])
      expect(snapshot.fetch("audit_id")).to be < staff_audit.id
      expect(Admissions::HistoricalScanAuthority.new(device: @device, download: latest)
        .allowed?(at: Time.iso8601(snapshot.fetch("captured_at")))).to be(true)
      post "#{@base}/#{@device.id}/#{operation}", params: params, headers: @headers
      expect(response).to have_http_status(:ok)
      expect(AdmissionAction.where(scanner_device: @device).count).to eq(1)
      expect(AuditLog.where(auditable: AdmissionAction.find_by!(action_uuid: input[:action_uuid]),
        action: "ticket.admission_reconciled").count).to eq(1)
      expect(MessageDelivery.where(template: "organization_invitation")).not_to exist
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  it "commits membership revocation before waiting for the scanning user's derived label" do
    @staff.update!(role: :organizer)
    owner = @event.organizer_profile.user
    owner_headers = auth_headers(owner).merge("X-Organization-Id" => @event.organization_id.to_s)
    ticket = create(:ticket, event: @event, order: create(:order, event: @event),
      ticket_type: create(:ticket_type, event: @event))
    get "#{@base}/#{@device.id}/manifest", headers: @headers
    input = { action_uuid: SecureRandom.uuid, sequence: 1, kind: "admit", source: "offline",
      ticket_id: ticket.id, credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential),
      manifest_version: response.parsed_body.dig("payload", "version"), occurred_at: Time.current.iso8601(6) }
    revoking, resume_revoke, completed, outcomes, connections = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
    allow(OrganizationInvitation).to receive(:revoke!).and_wrap_original do |original, *args|
      revoking << true
      Timeout.timeout(8) { resume_revoke.pop }
      original.call(*args)
    end
    workers = [worker(:revoke, outcomes, connections, completed) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.delete "/api/v1/organizer/memberships/#{@membership.id}", headers: owner_headers
      client.response.status
    end]
    revoke_pid = connections.pop.last
    Timeout.timeout(8) { revoking.pop } # ORG/membership held, target USER still free.
    workers << worker(:admission, outcomes, connections, completed) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post "#{@base}/#{@device.id}/sync", params: { actions: [input] }, headers: @headers
      [client.response.status, client.response.parsed_body]
    end
    admission_pid = connections.pop.last
    expect(admission_pid).not_to eq(revoke_pid)
    await { blocked_by?(admission_pid, revoke_pid) } # ACTOR -> revoker's ORG.
    resume_revoke << true # An in-transaction target USER update would close the cycle.
    Timeout.timeout(12) { workers.each(&:join) }
    results = 2.times.map { outcomes.pop }.to_h
    expect(results.values.grep(Exception)).to be_empty, results.inspect
    expect(results.fetch(:revoke)).to eq(204)
    expect(results.fetch(:admission)).to match([422, include("error" => "Scanner assignment is no longer active")])
    expect(@membership.reload).to be_status_revoked
    expect(@assignment.reload).to be_status_revoked
    expect(@staff.reload).to be_attendee
    expect(AuditLog.find_by!(auditable: @membership, action: "organization.membership_revoked"))
      .to have_attributes(actor_user_id: owner.id, organization_id: @event.organization_id)
    expect(AuditLog.where(auditable: @assignment, action: "event_staff.revoked").count).to eq(1)
    expect(AdmissionAction).not_to exist
    expect(@device.reload.last_sequence).to eq(0)
    expect(ticket.reload).to be_issued
  ensure
    workers&.each { |thread| thread.kill if thread.alive? }
    workers&.each(&:join)
  end

  it "discards a deferred label refresh on outer rollback or required revocation audit failure" do
    @staff.update!(role: :organizer)
    owner = @event.organizer_profile.user
    refreshed = []
    allow_any_instance_of(User).to receive(:sync_member_label!).and_wrap_original do |original|
      refreshed << original.receiver.id
      original.call
    end
    OrganizationMembership.transaction do
      OrganizationTeam.revoke!(membership: @membership, actor: owner)
      expect(@membership.reload).to be_status_revoked
      expect(@staff.reload).to be_organizer
      expect(refreshed).to be_empty
      raise ActiveRecord::Rollback
    end
    expect(@membership.reload).to be_status_active
    expect(@assignment.reload).to be_status_active
    expect(refreshed).to be_empty
    expect(AuditLog.where(auditable: @membership, action: "organization.membership_revoked")).not_to exist
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "organization.membership_revoked"))
      .and_raise(AuditLogger::WriteError, "synthetic required revocation audit failure")
    expect { OrganizationTeam.revoke!(membership: @membership, actor: owner) }.to raise_error(AuditLogger::WriteError)
    expect(@membership.reload).to be_status_active
    expect(@assignment.reload).to be_status_active
    expect(@staff.reload).to be_organizer
    expect(refreshed).to be_empty
    expect(AuditLog.where(auditable: @assignment, action: "event_staff.revoked")).not_to exist
  end

  it "derives a delayed post-commit label from the latest committed memberships" do
    @staff.update!(role: :organizer)
    owner_headers = auth_headers(@event.organizer_profile.user).merge("X-Organization-Id" => @event.organization_id.to_s)
    other_profile = create(:organizer_profile)
    other_membership = create(:organization_membership, organization: other_profile.organization,
      user: @staff, role: :scanner, expires_at: 1.minute.ago)
    other_headers = auth_headers(other_profile.user).merge("X-Organization-Id" => other_profile.organization_id.to_s)
    held, release, completed, outcomes, connections = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
    workers = [worker(:holder, outcomes, connections, completed) do
      User.find(@staff.id).with_lock("FOR NO KEY UPDATE") do
        held << true
        Timeout.timeout(8) { release.pop }
      end
      :released
    end]
    holder_pid = connections.pop.last
    Timeout.timeout(8) { held.pop }
    workers << worker(:revoke, outcomes, connections, completed) do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.delete "/api/v1/organizer/memberships/#{@membership.id}", headers: owner_headers
      client.response.status
    end
    revoke_pid = connections.pop.last
    await { blocked_by?(revoke_pid, holder_pid) }
    # The callback waits on USER only after revocation and its audit committed.
    expect(@membership.reload).to be_status_revoked
    expect(@assignment.reload).to be_status_revoked
    expect(AuditLog.where(auditable: @membership, action: "organization.membership_revoked").count).to eq(1)
    Organization.transaction { Organization.lock("FOR UPDATE NOWAIT").find(@event.organization_id) }
    patch "/api/v1/organizer/memberships/#{other_membership.id}",
      params: { role: "scanner", expires_at: nil }, headers: other_headers
    expect(response).to have_http_status(:ok)
    expect(other_membership.reload).to be_effective
    release << true
    Timeout.timeout(12) { workers.each(&:join) }
    expect(2.times.map { outcomes.pop }.to_h).to eq(holder: :released, revoke: 204)
    expect(@staff.reload).to be_organizer
    expect(@membership.reload).to be_status_revoked
    expect(@assignment.reload).to be_status_revoked
  ensure
    workers&.each { |thread| thread.kill if thread.alive? }
    workers&.each(&:join)
  end

  it "keeps invitation acceptance, its required audit and the synchronous user label in the outer transaction" do
    invitee = create(:user)
    headers = auth_headers(invitee)
    invitation = create(:organization_membership, organization: @event.organization, user: nil,
      invited_email: invitee.email, role: :manager, status: :invited, accepted_at: nil)
    token = OrganizationInvitation.issue!(invitation)
    OrganizationMembership.transaction do
      OrganizationInvitation.accept!(token: token, user: invitee)
      expect(invitation.reload).to be_status_active
      expect(invitee.reload).to be_organizer
      raise ActiveRecord::Rollback
    end
    expect(invitation.reload).to be_status_invited
    expect(invitee.reload).to be_attendee
    expect(AuditLog.where(auditable: invitation, action: "organization.invitation_accepted")).not_to exist
    allow(AuditLogger).to receive(:record!).and_call_original
    allow(AuditLogger).to receive(:record!).with(hash_including(action: "organization.invitation_accepted"))
      .and_raise(AuditLogger::WriteError, "synthetic required acceptance audit failure")
    expect { OrganizationInvitation.accept!(token: token, user: invitee) }.to raise_error(AuditLogger::WriteError)
    expect(invitation.reload).to be_status_invited
    expect(invitee.reload).to be_attendee
    allow(AuditLogger).to receive(:record!).and_call_original
    post "/api/v1/organization_invitations/accept", params: { token: token }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(invitation.reload).to be_status_active
    expect(invitee.reload).to be_organizer
    expect(AuditLog.where(auditable: invitation, action: "organization.invitation_accepted").count).to eq(1)
  end

  %i[rename revoke].each do |operation|
    it "finishes a manifest download racing an audited scanner #{operation}" do
      @membership.update!(role: :manager)
      download_ready, resume_download, completed, outcomes, connections = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
      allow_any_instance_of(ScannerDevice).to receive(:lock!).and_wrap_original do |original, *args|
        if Thread.current[:scanner_worker] == :download && !Thread.current[:paused_device]
          Thread.current[:paused_device] = true
          download_ready << true
          Timeout.timeout(8) { resume_download.pop }
        end
        original.call(*args)
      end
      workers = [worker(:download, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.get "#{@base}/#{@device.id}/manifest", headers: @headers
        client.response.status
      end]
      download_pid = connections.pop.last
      Timeout.timeout(8) { download_ready.pop }
      workers << worker(:mutation, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        if operation == :rename
          client.patch "#{@base}/#{@device.id}", params: { name: "Renamed gate" }, headers: @headers
        else
          client.delete "#{@base}/#{@device.id}", headers: @headers
        end
        client.response.status
      end
      mutation_pid = connections.pop.last
      await { blocked_by?(mutation_pid, download_pid) }
      resume_download << true
      Timeout.timeout(12) { workers.each(&:join) }
      results = 2.times.map { outcomes.pop }.to_h
      expect(results).to eq(download: 200, mutation: operation == :rename ? 200 : 204)
      action = operation == :rename ? "scanner_device.renamed" : "scanner_device.revoked"
      expect(AuditLog.where(auditable: @device, action: action).count).to eq(1)
      expect(download_audits.count).to eq(1)
      expect(download_audits.sole.after_data.fetch("lease_expires_at")).to eq(@original_lease.iso8601(6))
      expect(@device.reload.name).to eq("Renamed gate") if operation == :rename
      expect(@device.reload).to be_status_revoked if operation == :revoke
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
  end

  %i[sales activity_log].each do |export|
    it "finishes a new manifest while a same-actor #{export} export waits for its organization audit" do
      @membership.update!(role: :manager)
      path = export == :sales ? "/api/v1/organizer/events/#{@event.id}/sales_exports" : "/api/v1/organizer/activity_log_exports"
      ready, release, completed, outcomes, connections = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
      allow_any_instance_of(ScannerDevice).to receive(:lock!).and_wrap_original do |original, *args|
        if Thread.current[:scanner_worker] == :download && !Thread.current[:paused_device]
          Thread.current[:paused_device] = true
          ready << true
          Timeout.timeout(8) { release.pop }
        end
        original.call(*args)
      end
      workers = [worker(:download, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.get "#{@base}/#{@device.id}/manifest", headers: @headers
        client.response.status
      end]
      download_pid = connections.pop.last
      Timeout.timeout(8) { ready.pop }
      workers << worker(:export, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post path, headers: @headers
        client.response.status
      end
      export_pid = connections.pop.last
      await { blocked_by?(export_pid, download_pid) } # Export holds USER; its audit needs ORG FK KEY SHARE.
      release << true # New manifest needs generated_by_user FK KEY SHARE of that same USER.
      Timeout.timeout(12) { workers.each(&:join) }
      expect(2.times.map { outcomes.pop }.to_h).to eq(download: 200, export: export == :sales ? 200 : 201)
      expect(AuditLog.where(actor_user: @staff, action: "#{export}.export_requested").count).to eq(1)
      expect(@event.admission_manifests.sole.generated_by_user_id).to eq(@staff.id)
      expect(download_audits.count).to eq(1)
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end

    it "serializes concurrent same-actor #{export} exports at the ten-request quota" do
      @membership.update!(role: :manager)
      path = export == :sales ? "/api/v1/organizer/events/#{@event.id}/sales_exports" : "/api/v1/organizer/activity_log_exports"
      9.times do
        AuditLogger.record!(action: "#{export}.export_requested", auditable: @event,
          actor: @staff, organization: @event.organization)
      end
      ready, release, completed, outcomes, connections = Queue.new, Queue.new, Queue.new, Queue.new, Queue.new
      allow_any_instance_of(User).to receive(:lock!).and_wrap_original do |original, *args|
        result = original.call(*args)
        if Thread.current[:scanner_worker] == :first_export && !Thread.current[:paused_actor]
          Thread.current[:paused_actor] = true
          ready << true
          Timeout.timeout(8) { release.pop }
        end
        result
      end
      workers = [worker(:first_export, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post path, headers: @headers
        client.response.status
      end]
      first_pid = connections.pop.last
      Timeout.timeout(8) { ready.pop }
      workers << worker(:second_export, outcomes, connections, completed) do
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post path, headers: @headers
        client.response.status
      end
      second_pid = connections.pop.last
      await { blocked_by?(second_pid, first_pid) } # NO KEY UPDATE still conflicts with itself.
      release << true
      Timeout.timeout(12) { workers.each(&:join) }
      expect(2.times.map { outcomes.pop }.to_h)
        .to eq(first_export: export == :sales ? 200 : 201, second_export: 429)
      expect(AuditLog.where(actor_user: @staff, action: "#{export}.export_requested").count).to eq(10)
    ensure
      workers&.each { |thread| thread.kill if thread.alive? }
      workers&.each(&:join)
    end
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
