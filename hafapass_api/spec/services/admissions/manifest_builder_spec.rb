# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admissions::ManifestBuilder do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event) }
  let(:order) { create(:order, event: event, buyer_email: "door@example.com", buyer_name: "Door Guest") }
  let!(:ticket) { create(:ticket, event: event, order: order, ticket_type: ticket_type) }

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

  it "creates a new immutable version when a ticket credential or state changes" do
    original = described_class.call(event: event, actor: profile.user)
    ticket.rotate_scan_credential!
    revised = described_class.call(event: event, actor: profile.user)

    expect(revised.version).to eq(2)
    expect(revised.digest).not_to eq(original.digest)
    expect { original.update!(ticket_count: 99) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
    expect(original.reload.ticket_count).to eq(1)
  end
end
