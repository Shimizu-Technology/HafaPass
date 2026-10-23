# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operational audit coverage" do
  it "audits each implicit staff revocation and retains the target and prior role" do
    event = create(:event)
    member = create(:organization_membership, organization: event.organization, role: :scanner)
    assignment = create(:event_staff_assignment, event: event, user: member.user)
    owner = event.organizer_profile.user
    OrganizationTeam.revoke!(membership: member, actor: owner)
    row = AuditLog.find_by!(action: "event_staff.revoked", auditable: assignment)
    expect(row).to have_attributes(actor_user: owner, organization: event.organization, event: event)
    expect(row.before_data).to include("role" => "scanner", "status" => "active", "target_user_id" => member.user_id)
    expect(row.after_data).to include("status" => "revoked")
    removal = AuditLog.find_by!(action: "organization.membership_revoked", auditable: member)
    expect(removal.before_data).to include("role" => "scanner", "target_user_id" => member.user_id)
  end

  it "records scanner rename and manifest download without copying the manifest" do
    device = create(:scanner_device)
    actor = device.user
    AuditContext.set(actor: actor, source: "user") do
      device.update!(name: "North entrance")
      device.update!(manifest_downloaded_at: Time.current, last_manifest_version: 4)
    end
    rename = AuditLog.find_by!(action: "scanner_device.renamed", auditable: device)
    manifest = AuditLog.find_by!(action: "scanner_device.manifest_downloaded", auditable: device)
    expect(rename.actor_user).to eq(actor)
    expect(rename.after_data).to eq("name" => "North entrance")
    expect(manifest).to have_attributes(organization: device.organization, event: device.event)
    expect(manifest.after_data).to include("manifest_version" => 4)
    expect(manifest.after_data).not_to have_key("payload")
  end

  it "attributes campaign sends to the sender rather than the campaign creator" do
    campaign = create(:communication_campaign)
    campaign.event.organization.update!(marketing_mailing_address: "123 Marine Drive, Hagåtña, GU 96910",
      marketing_address_certified_at: Time.current)
    sender = create(:user)
    CommunicationCampaigns::Sender.call(campaign, actor: sender)
    rows = AuditLog.where(auditable: campaign, action: %w[campaign.send_requested campaign.send_completed]).order(:id)
    expect(rows.map(&:actor_user_id)).to eq([sender.id, sender.id])
    expect(rows.map(&:outcome)).to eq(%w[requested succeeded])
    expect(rows.map(&:organization_id).uniq).to eq([campaign.event.organization_id])
  end
end
