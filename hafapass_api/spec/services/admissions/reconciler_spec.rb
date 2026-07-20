# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::Reconciler do
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

  it "returns the original result for an exact action retry" do
    input = scan_input(sequence: 1, uuid: "idempotent-door-scan")
    original = described_class.call(device: device, actor: actor, actions: [input]).first.action
    replay = described_class.call(device: device.reload, actor: actor, actions: [input]).first.action

    expect(replay).to eq(original)
    expect(AdmissionAction.where(action_uuid: input.fetch(:action_uuid)).count).to eq(1)
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
