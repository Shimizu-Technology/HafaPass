# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::Reconciler do
  include ActiveSupport::Testing::TimeHelpers
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:actor) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event) }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type) }
  let(:device) { create(:scanner_device, organization: organization, event: event, user: actor) }
  let(:manifest) { Admissions::ManifestBuilder.call(event: event, actor: actor) }

  def scan_input(sequence:, uuid:, scanner_manifest: manifest, source: "offline", **overrides)
    entry = scanner_manifest.payload.fetch("tickets").find { |item| item.fetch("ticket_id") == ticket.id }
    {
      action_uuid: uuid,
      kind: "admit",
      source: source,
      sequence: sequence,
      manifest_version: scanner_manifest.version,
      occurred_at: Time.current.iso8601(6),
      ticket_id: ticket.id,
      credential_hash: entry.fetch("credential_hash")
    }.merge(overrides)
  end

  it "accepts one admission, surfaces a second-device conflict, and reverses append-only" do
    first = described_class.call(device: device, actor: actor,
      actions: [scan_input(sequence: 1, uuid: "first-door-scan")]).first
    expect(first.action).to be_result_accepted
    expect(ticket.reload).to be_checked_in

    second_device = create(:scanner_device, organization: organization, event: event, user: actor)
    duplicate = described_class.call(device: second_device, actor: actor,
      actions: [scan_input(sequence: 1, uuid: "second-door-scan")]).first
    expect(duplicate.action).to be_result_conflict
    expect(duplicate.action.reason_code).to eq("already_admitted")

    reversal = described_class.call(device: device, actor: actor, actions: [{
      action_uuid: "reverse-door-scan",
      kind: "reverse",
      source: "online",
      sequence: 2,
      manifest_version: manifest.version,
      occurred_at: Time.current.iso8601(6),
      reverses_action_uuid: first.action.action_uuid
    }]).first
    expect(reversal.action).to be_result_accepted
    expect(reversal.action.reverses_action).to eq(first.action)
    expect(ticket.reload).to be_issued
    expect { first.action.update!(reason_code: "rewritten") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
  end

  it "rejects invalid, revoked, stale, and unauthorized offline actions without false admission" do
    invalid = described_class.call(device: device, actor: actor, actions: [
      scan_input(sequence: 1, uuid: "invalid-hash", credential_hash: "0" * 64)
    ]).first
    expect(invalid.action).to have_attributes(result: "rejected", reason_code: "credential_not_in_manifest")
    expect(ticket.reload).to be_issued

    old_manifest = manifest
    ticket.rotate_scan_credential!
    revoked = described_class.call(device: device, actor: actor, actions: [
      scan_input(sequence: 2, uuid: "revoked-hash", scanner_manifest: old_manifest)
    ]).first
    expect(revoked.action).to have_attributes(result: "rejected", reason_code: "credential_revoked")

    device.revoke!
    expect do
      described_class.call(device: device, actor: actor, actions: [
        scan_input(sequence: 3, uuid: "revoked-device", scanner_manifest: old_manifest)
      ])
    end.to raise_error(described_class::SyncError, /expired or was revoked/)
  end

  %w[online offline].each do |source|
    it "rejects #{source} reconciliation from an older valid manifest after a selected refund is reserved" do
      prepared = manifest
      refund = create(:refund, order: order, status: :pending, provider_refund_id: nil,
        succeeded_at: nil, failure_code: "provider_result_unknown")
      refund.refund_tickets.create!(ticket: ticket, amount_cents: refund.amount_cents)
      input = scan_input(sequence: 1, uuid: "pending-refund-#{source}", scanner_manifest: prepared, source: source)
      result = described_class.call(device: device, actor: actor, actions: [input]).first.action
      expect(result).to have_attributes(result: "rejected", reason_code: "refund_pending")
      expect(ticket.reload).to be_issued
      expect(described_class.call(device: device.reload, actor: actor, actions: [input]).first.action).to eq(result)
      expect(refund.reload).to be_pending
    end
  end

  it "returns the original result for an exact action retry" do
    input = scan_input(sequence: 1, uuid: "idempotent-door-scan")
    original = described_class.call(device: device, actor: actor, actions: [input]).first.action
    replay = described_class.call(device: device.reload, actor: actor, actions: [input]).first.action

    expect(replay).to eq(original)
    expect(AdmissionAction.where(action_uuid: input.fetch(:action_uuid)).count).to eq(1)
  end

  it "refuses a device revoked after batch validation but before its row lock" do
    input = scan_input(sequence: 1, uuid: "revoked-during-lock")
    allow(device).to receive(:lock!).and_wrap_original do |original|
      ScannerDevice.find(device.id).revoke!
      original.call
    end
    expect { described_class.call(device: device, actor: actor, actions: [input]) }
      .to raise_error(described_class::SyncError, /expired or was revoked/)
    expect(ticket.reload).to be_issued
    expect(event.admission_actions).to be_empty
  end

  it "rechecks the staff assignment after waiting for the device lock" do
    staff = create(:user)
    create(:organization_membership, organization: organization, user: staff, role: :scanner)
    assignment = create(:event_staff_assignment, organization: organization, event: event, user: staff, role: :scanner)
    device.update!(user: staff)
    input = scan_input(sequence: 1, uuid: "assignment-revoked-during-lock")
    allow(device).to receive(:lock!).and_wrap_original do |original|
      assignment.update!(status: :revoked)
      original.call
    end
    expect { described_class.call(device: device, actor: staff, actions: [input]) }
      .to raise_error(described_class::SyncError, /assignment is no longer active/)
    expect(ticket.reload).to be_issued
    expect(event.admission_actions).to be_empty
  end

  it "does not admit after authorization expires while waiting for the order lock" do
    input = scan_input(sequence: 1, uuid: "expired-during-order-lock")
    expires_at = 2.minutes.from_now
    device.update!(authorization_expires_at: expires_at)
    allow_any_instance_of(Order).to receive(:lock!).and_wrap_original do |original|
      travel_to(expires_at + 1.second)
      original.call
    end
    expect { described_class.call(device: device, actor: actor, actions: [input]) }
      .to raise_error(described_class::SyncError, /expired or was revoked/)
    expect(ticket.reload).to be_issued
    expect(event.admission_actions).to be_empty
  ensure
    travel_back
  end

  it "acknowledges a repeated undo as an immutable conflict and replays its own identity" do
    admitted = described_class.call(device: device, actor: actor,
      actions: [scan_input(sequence: 1, uuid: "repeat-undo-admission")]).first.action
    reversal = {
      action_uuid: "first-undo", kind: "reverse", source: "online", sequence: 2,
      manifest_version: manifest.version, occurred_at: Time.current.iso8601(6), reverses_action_uuid: admitted.action_uuid
    }
    accepted = described_class.call(device: device, actor: actor, actions: [reversal]).first.action
    repeated = reversal.merge(action_uuid: "second-undo", sequence: 3)
    conflict = described_class.call(device: device, actor: actor, actions: [repeated]).first.action
    expect(conflict).to have_attributes(action_uuid: "second-undo", result: "conflict", reason_code: "already_reversed", kind: "reverse")
    expect(conflict.reverses_action).to eq(admitted)
    expect(admitted.reload.reversal_action).to eq(accepted)
    expect(ticket.reload).to be_issued
    expect(device.reload.last_sequence).to eq(3)
    replay = described_class.call(device: device, actor: actor, actions: [repeated]).first.action
    expect(replay.id).to eq(conflict.id)
    expect(event.admission_actions.count).to eq(3)
    require Rails.root.join("db/migrate/20261010113000_preserve_rejected_admission_reversals").to_s
    expect { PreserveRejectedAdmissionReversals.new.down }
      .to raise_error(ActiveRecord::IrreversibleMigration, /without deleting admission reversal history/)
  end

  it "records a rejected unknown reversal so its journal can be acknowledged without changing a ticket" do
    input = {
      action_uuid: "missing-admission-undo", kind: "reverse", source: "online", sequence: 1,
      manifest_version: manifest.version, occurred_at: Time.current.iso8601(6), reverses_action_uuid: "missing-admission"
    }
    result = described_class.call(device: device, actor: actor, actions: [input]).first.action
    expect(result).to have_attributes(kind: "reverse", result: "rejected", reason_code: "admission_not_found")
    expect(ticket.reload).to be_issued
    expect(described_class.call(device: device, actor: actor, actions: [input]).first.action).to eq(result)
    expect(event.admission_actions.count).to eq(1)
  end

  it "acknowledges a scanner's refused Undo without changing the original admission or preventing a manager's Undo" do
    admitted = described_class.call(device: device, actor: actor,
      actions: [scan_input(sequence: 1, uuid: "manager-admission")]).first.action
    staff = create(:user)
    create(:organization_membership, organization: organization, user: staff, role: :scanner)
    create(:event_staff_assignment, organization: organization, event: event, user: staff, role: :scanner)
    staff_device = create(:scanner_device, organization: organization, event: event, user: staff)
    input = { action_uuid: "staff-undo", kind: "reverse", source: "online", sequence: 1,
      manifest_version: manifest.version, occurred_at: Time.current.iso8601(6), reverses_action_uuid: admitted.action_uuid }
    refused = described_class.call(device: staff_device, actor: staff, actions: [input]).first.action
    expect(refused).to have_attributes(result: "rejected", reason_code: "reversal_not_authorized", ticket_id: ticket.id)
    expect(admitted.reload.reversal_action).to be_nil
    expect(ticket.reload).to be_checked_in
    authorized = described_class.call(device: device, actor: actor, actions: [input.merge(action_uuid: "authorized-undo", sequence: 2)]).first.action
    expect(authorized).to be_result_accepted
    expect(ticket.reload).to be_issued
  end

  it "rejects malformed or ambiguous client actions before writing admission history" do
    expect do
      described_class.call(device: device, actor: actor, actions: ["not-an-action"])
    end.to raise_error(described_class::SyncError, /must be an object/)

    expect do
      described_class.call(device: device, actor: actor, actions: [
        scan_input(sequence: 1, uuid: "unsupported-action", kind: "permit")
      ])
    end.to raise_error(described_class::SyncError, /valid kind/)
    expect(event.admission_actions).to be_empty
  end
end
