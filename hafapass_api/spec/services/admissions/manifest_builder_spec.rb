# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::ManifestBuilder do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event, buyer_email: "door@example.com", buyer_name: "Door Guest") }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type) }

  it "matches browser JSON.stringify bytes for schema scalars, controls, and Unicode" do
    value = { "z" => ["A\tB\nC\r\"\\", nil, true, false, 17],
      "event" => { "title" => "Music & Food <show> 🎟️ José\u2028", "id" => 9 } }
    # SHA-256 of the recursively sorted JSON.stringify representation, independently
    # generated in Node. Rails HTML escaping must not alter signed protocol bytes.
    expect(Digest::SHA256.hexdigest(described_class.canonical_json(value)))
      .to eq("75f44dd8bb67cc39d30cd34741caa6a9867b0b01a28cc3e764922ad59d485d4a")
  end

  it "builds a reusable signed manifest with only door-safe attendee data" do
    manifest = described_class.call(event: event, actor: profile.user)

    expect(manifest).to have_attributes(version: 1, ticket_count: 1, algorithm: "PS256")
    expect(Admissions::ManifestSigner.verify(digest: manifest.digest, signature: manifest.signature)).to be(true)
    expect(Digest::SHA256.hexdigest(described_class.canonical_json(manifest.payload))).to eq(manifest.digest)
    expect(manifest.payload.dig("tickets", 0)).to include(
      "ticket_id" => ticket.id,
      "attendee_name" => "Door Guest",
      "ticket_type" => "General Admission",
      "state" => "valid"
    )
    expect(manifest.payload.to_json).not_to include("door@example.com", ticket.scan_credential)
    expect(described_class.call(event: event, actor: profile.user)).to eq(manifest)
  end

  it "signs a new refund-blocked version and restores eligibility only after a definitive failure" do
    original = described_class.call(event: event, actor: profile.user)
    refund = create(:refund, order: order, status: :pending, provider_refund_id: nil, succeeded_at: nil,
      failure_code: "provider_result_unknown")
    refund.refund_tickets.create!(ticket: ticket, amount_cents: refund.amount_cents)

    blocked = described_class.call(event: event, actor: profile.user)
    expect(blocked.version).to eq(original.version + 1)
    expect(blocked.payload.dig("tickets", 0, "state")).to eq("refund_pending")
    expect(Admissions::ManifestSigner.verify(digest: blocked.digest, signature: blocked.signature)).to be(true)
    expect(original.reload.payload.dig("tickets", 0, "state")).to eq("valid")
    expect(ticket.reload).not_to be_admission_allowed

    Commerce::RefundCreator.reconcile_refund!(refund: refund,
      provider_refund: OpenStruct.new(id: "re_synthetic_failed", status: "failed"))
    renewed = described_class.call(event: event, actor: profile.user)
    expect(renewed.version).to eq(blocked.version + 1)
    expect(renewed.payload.dig("tickets", 0, "state")).to eq("valid")
    expect(refund.reload).to be_failed
    expect(ticket.reload).to be_admission_allowed
  end

  it "creates a new immutable version when a ticket credential or state changes" do
    original = described_class.call(event: event, actor: profile.user)
    ticket.rotate_scan_credential!
    revised = described_class.call(event: event, actor: profile.user)

    expect(revised.version).to eq(2)
    expect(revised.digest).not_to eq(original.digest)
    expect { original.update!(ticket_count: 99) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(original.reload.ticket_count).to eq(1)
  end

  it "signs exact accepted reversal proofs across independent staff and manager devices" do
    staff = create(:user)
    create(:organization_membership, organization: profile.organization, user: staff, role: :scanner)
    create(:event_staff_assignment, organization: profile.organization, event: event, user: staff, role: :scanner)
    staff_device = create(:scanner_device, organization: profile.organization, event: event, user: staff)
    manager_device = create(:scanner_device, organization: profile.organization, event: event, user: profile.user)
    prepared = described_class.call(event: event, actor: staff)
    scan = { action_uuid: "staff-first", kind: "admit", source: "online", sequence: 1,
      manifest_version: prepared.version, occurred_at: Time.current.iso8601(6), ticket_id: ticket.id,
      credential_hash: Digest::SHA256.hexdigest(ticket.scan_credential) }
    admitted = Admissions::Reconciler.call(device: staff_device, actor: staff, actions: [scan]).first.action
    admitted_manifest = described_class.call(event: event, actor: staff)
    expect(admitted_manifest.payload.dig("tickets", 0, "state")).to eq("admitted")
    undo = { action_uuid: "manager-first-undo", kind: "reverse", source: "online", sequence: 1,
      manifest_version: admitted_manifest.version, occurred_at: Time.current.iso8601(6), reverses_action_uuid: admitted.action_uuid }
    reversed = Admissions::Reconciler.call(device: manager_device, actor: profile.user, actions: [undo]).first.action
    repeated = Admissions::Reconciler.call(device: manager_device, actor: profile.user,
      actions: [undo.merge(action_uuid: "manager-repeat-undo", sequence: 2)]).first.action
    expect(reversed).to be_result_accepted
    expect(repeated).to be_result_conflict
    expect(ticket.reload).to be_issued
    refreshed = described_class.call(event: event, actor: staff)
    expect(refreshed.payload.dig("tickets", 0)).to include("state" => "valid",
      "reversed_admission_action_uuids" => [admitted.action_uuid])
    expect(Admissions::ManifestSigner.verify(digest: refreshed.digest, signature: refreshed.signature)).to be(true)

    later = Admissions::Reconciler.call(device: staff_device, actor: staff,
      actions: [scan.merge(action_uuid: "staff-later", sequence: 2, manifest_version: refreshed.version,
        occurred_at: Time.current.iso8601(6))]).first.action
    expect(later).to be_result_accepted
    later_manifest = described_class.call(event: event, actor: staff)
    expect(later_manifest.payload.dig("tickets", 0)).to include("state" => "admitted",
      "reversed_admission_action_uuids" => [admitted.action_uuid])
    stale_undo = Admissions::Reconciler.call(device: manager_device, actor: profile.user,
      actions: [undo.merge(action_uuid: "manager-stale-first-undo", sequence: 3)]).first.action
    expect(stale_undo).to be_result_conflict
    expect(stale_undo.reason_code).to eq("already_reversed")
    expect(ticket.reload).to be_checked_in
    Admissions::Reconciler.call(device: manager_device, actor: profile.user,
      actions: [undo.merge(action_uuid: "manager-later-undo", sequence: 4, reverses_action_uuid: later.action_uuid)]).first
    final_manifest = described_class.call(event: event, actor: staff)
    expect(final_manifest.payload.dig("tickets", 0)).to include("state" => "valid",
      "reversed_admission_action_uuids" => [admitted.action_uuid, later.action_uuid].sort)
    expect(described_class.call(event: event, actor: staff)).to eq(final_manifest)
  end
end
