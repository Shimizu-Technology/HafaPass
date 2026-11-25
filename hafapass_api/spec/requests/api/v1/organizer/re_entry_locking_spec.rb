# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe "Re-entry concurrent scan locking", type: :request do
  self.use_transactional_tests = false

  before do
    raise "Concurrency tests require test" unless Rails.env.test?

    clean_data
    @profile = create(:organizer_profile)
    @org = @profile.organization
    @event = create(:event, :published, organizer_profile: @profile, re_entry_mode: "exit_scan",
      starts_at: 1.hour.ago, ends_at: 12.hours.from_now)
    @staff_a = create(:user)
    @staff_b = create(:user)
    create(:organization_membership, organization: @org, user: @staff_a, role: :scanner)
    create(:event_staff_assignment, organization: @org, event: @event, user: @staff_a, role: :scanner)
    create(:organization_membership, organization: @org, user: @staff_b, role: :scanner)
    create(:event_staff_assignment, organization: @org, event: @event, user: @staff_b, role: :scanner_lead)
    @device_a = Admissions::DeviceRegistrar.call(event: @event, user: @staff_a, identifier: "race-a", name: "Gate A")
    @device_b = Admissions::DeviceRegistrar.call(event: @event, user: @staff_b, identifier: "race-b", name: "Gate B")
    @type = create(:ticket_type, event: @event)
    @order = create(:order, event: @event)
    @ticket = create(:ticket, event: @event, order: @order, ticket_type: @type, attendee_name: "Elowen Marsh")
    @manifest = Admissions::ManifestBuilder.call(event: @event, actor: @staff_a)
  end

  after { clean_data }

  def clean_data
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.execute("TRUNCATE TABLE audit_logs, admission_actions, admission_manifests, scanner_devices, tickets, order_items, orders, ticket_types, event_staff_assignments, organization_memberships, events, organizer_profiles, organizations, users RESTART IDENTITY CASCADE")
    end
  end

  def spawn_worker(name, outcomes, connections)
    Thread.new do
      Thread.current[:re_entry_worker] = name
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        conn.execute("SET lock_timeout = '5s'")
        pid = conn.select_value("SELECT pg_backend_pid()").to_i
        connections << [name, pid]
        outcomes << [name, yield]
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      outcomes << [name, e]
    end
  end

  it "serializes two devices scanning the same ticket simultaneously with one accept and one already_inside conflict" do
    locked = Queue.new
    resume = Queue.new
    outcomes = Queue.new
    connections = Queue.new

    allow_any_instance_of(Ticket).to receive(:lock!).and_wrap_original do |original, *args|
      result = original.call(*args)
      if Thread.current[:re_entry_worker] == :gate_a && !Thread.current[:held_ticket_lock]
        Thread.current[:held_ticket_lock] = true
        locked << true
        Timeout.timeout(8) { resume.pop }
      end
      result
    end

    cred_hash = Digest::SHA256.hexdigest(@ticket.scan_credential)
    now = Time.current.iso8601(6)

    w1 = spawn_worker(:gate_a, outcomes, connections) do
      Admissions::Reconciler.call(device: @device_a, actor: @staff_a, actions: [{
        action_uuid: "race-gate-a-1", kind: "admit", source: "online", sequence: 1,
        manifest_version: @manifest.version, occurred_at: now, ticket_id: @ticket.id, credential_hash: cred_hash
      }]).first.action
    end
    pid_a = connections.pop.last
    Timeout.timeout(8) { locked.pop }

    w2 = spawn_worker(:gate_b, outcomes, connections) do
      Admissions::Reconciler.call(device: @device_b, actor: @staff_b, actions: [{
        action_uuid: "race-gate-b-1", kind: "admit", source: "online", sequence: 1,
        manifest_version: @manifest.version, occurred_at: now, ticket_id: @ticket.id, credential_hash: cred_hash
      }]).first.action
    end
    pid_b = connections.pop.last
    expect(pid_a).not_to eq(pid_b)

    # Wait until worker B is genuinely waiting on PostgreSQL lock held by worker A
    Timeout.timeout(5) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{pid_b})")
        break if blockers.to_s.include?(pid_a.to_s)
        sleep 0.02
      end
    end

    resume << true
    Timeout.timeout(10) { [w1, w2].each(&:join) }

    results = 2.times.map { outcomes.pop }.to_h
    expect(results.values.grep(Exception)).to be_empty, results.inspect

    expect(results[:gate_a]).to have_attributes(result: "accepted", reason_code: "admitted")
    expect(results[:gate_b]).to have_attributes(result: "conflict", reason_code: "already_inside")
    expect(@ticket.reload).to have_attributes(occupancy_state: "inside", last_entry_device_id: @device_a.id)
    expect(Admissions::Counts.call(event: @event)).to include(live_headcount: 1, conflicts: 1)
  ensure
    [w1, w2].compact.each { |t| t.kill if t.alive? }
    [w1, w2].compact.each(&:join)
  end

  it "serializes concurrent lead override and gate exit scan without deadlock" do
    cred_hash = Digest::SHA256.hexdigest(@ticket.scan_credential)
    Admissions::Reconciler.call(device: @device_a, actor: @staff_a, actions: [{
      action_uuid: "seed-entry", kind: "admit", source: "online", sequence: 1,
      manifest_version: @manifest.version, occurred_at: Time.current.iso8601(6),
      ticket_id: @ticket.id, credential_hash: cred_hash
    }])
    expect(@ticket.reload.occupancy_state).to eq("inside")

    locked = Queue.new
    resume = Queue.new
    outcomes = Queue.new
    connections = Queue.new

    allow_any_instance_of(Ticket).to receive(:lock!).and_wrap_original do |original, *args|
      result = original.call(*args)
      if Thread.current[:re_entry_worker] == :override && !Thread.current[:held_ticket_lock]
        Thread.current[:held_ticket_lock] = true
        locked << true
        Timeout.timeout(8) { resume.pop }
      end
      result
    end

    w1 = spawn_worker(:override, outcomes, connections) do
      Admissions::LeadOverride.call(
        event: @event, actor: @staff_b, ticket_id: @ticket.id,
        override_action: "clear", reason: "Lead clearing inside state during race test",
        device: @device_b
      ).action
    end
    pid_override = connections.pop.last
    Timeout.timeout(8) { locked.pop }

    w2 = spawn_worker(:exit_scan, outcomes, connections) do
      Admissions::Reconciler.call(device: @device_a, actor: @staff_a, actions: [{
        action_uuid: "race-exit-1", kind: "exit", source: "online", sequence: 2,
        manifest_version: @manifest.version, occurred_at: Time.current.iso8601(6),
        ticket_id: @ticket.id, credential_hash: cred_hash
      }]).first.action
    end
    pid_exit = connections.pop.last
    expect(pid_override).not_to eq(pid_exit)

    Timeout.timeout(5) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{pid_exit})")
        break if blockers.to_s.include?(pid_override.to_s)
        sleep 0.02
      end
    end

    resume << true
    Timeout.timeout(10) { [w1, w2].each(&:join) }

    results = 2.times.map { outcomes.pop }.to_h
    expect(results.values.grep(Exception)).to be_empty, results.inspect
    expect(results[:override]).to have_attributes(result: "accepted", reason_code: "lead_override_cleared")
    expect(results[:exit_scan]).to have_attributes(result: "conflict", reason_code: "not_inside")
    expect(@ticket.reload.occupancy_state).to eq("outside")
    expect(Admissions::Counts.call(event: @event)[:live_headcount]).to eq(0)
  ensure
    [w1, w2].compact.each { |t| t.kill if t.alive? }
    [w1, w2].compact.each(&:join)
  end
end
