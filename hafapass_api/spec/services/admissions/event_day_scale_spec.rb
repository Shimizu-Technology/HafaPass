# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Event-day scale and multi-device reconciliation" do
  let(:profile) { create(:organizer_profile) }
  let(:organization) { profile.organization }
  let(:actor) { profile.user }
  let(:event) { create(:event, :published, organizer_profile: profile) }
  let(:ticket_type) { create(:ticket_type, event: event, quantity_available: 600) }
  let(:order) { create(:order, event: event) }
  let!(:tickets) { create_list(:ticket, 500, event: event, order: order, ticket_type: ticket_type) }
  let(:manifest) { Admissions::ManifestBuilder.call(event: event, actor: actor) }

  def input(ticket, device, sequence, uuid)
    entry = manifest.payload.fetch("tickets").find { |candidate| candidate.fetch("ticket_id") == ticket.id }
    {
      action_uuid: uuid,
      kind: "admit",
      source: "offline",
      sequence: sequence,
      manifest_version: manifest.version,
      occurred_at: Time.current.iso8601(6),
      ticket_id: ticket.id,
      credential_hash: entry.fetch("credential_hash")
    }
  end

  it "builds a 500-ticket manifest, reconciles three restored devices, and keeps online p95 below 500ms" do
    expect(manifest.ticket_count).to eq(500)
    devices = 3.times.map do |index|
      create(:scanner_device, organization: organization, event: event, user: actor, identifier: "scale-device-#{index}")
    end

    first = Admissions::Reconciler.call(device: devices[0], actor: actor,
      actions: [input(tickets[0], devices[0], 1, "scale-first")]).first
    second = Admissions::Reconciler.call(device: devices[1], actor: actor,
      actions: [input(tickets[1], devices[1], 1, "scale-second")]).first
    duplicate = Admissions::Reconciler.call(device: devices[2], actor: actor,
      actions: [input(tickets[0], devices[2], 1, "scale-conflict")]).first

    expect([first.action.result, second.action.result, duplicate.action.result]).to eq(%w[accepted accepted conflict])
    samples = tickets.drop(2).first(20).each_with_index.map do |ticket, index|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Admissions::Reconciler.call(device: devices[0].reload, actor: actor,
        actions: [input(ticket, devices[0], index + 2, "scale-online-#{index}").merge(source: "online")])
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    end.sort
    p95 = samples[(samples.length * 0.95).ceil - 1]
    expect(p95).to be < 500
  end
end
