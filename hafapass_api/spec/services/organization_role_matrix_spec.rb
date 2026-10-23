# frozen_string_literal: true

# This contract deliberately runs without Rails, a database or any services.
require "spec_helper"
require "json"
require_relative "../../app/services/organization_roles"
require_relative "../../app/services/organization_authorization"
require_relative "../../app/services/organization_role_matrix"

RSpec.describe OrganizationRoleMatrix do
  def values(key)
    described_class.data.fetch(:rows).find { |row| row[:key] == key }.fetch(:values)
  end

  it "keeps the frontend artifact current with backend labels, permissions and assignment scopes" do
    artifact = File.expand_path("../../../hafapass_frontend/src/generated/roleMatrix.json", __dir__)
    expect(File.read(artifact)).to eq("#{JSON.pretty_generate(described_class.data)}\n"),
      "Role matrix is stale. Run ruby hafapass_api/script/generate_role_matrix.rb from the repository root."
  end

  it "keeps the documented table current with the same generated values and caveats" do
    document = File.expand_path("../../../docs/ROLE_MATRIX.md", __dir__)
    expect(File.read(document)).to eq(described_class.markdown),
      "Role matrix documentation is stale. Run ruby hafapass_api/script/generate_role_matrix.rb."
  end

  it "uses exactly the requested ordered roles and rows" do
    expect(described_class.data[:roles]).to eq([
      { key: "owner", label: "Owner" }, { key: "manager", label: "Manager" },
      { key: "finance", label: "Finance" }, { key: "marketer", label: "Marketer" },
      { key: "box_office", label: "Box office" }, { key: "scanner", label: "Door scanner" }
    ])
    expect(described_class.data[:rows].map { |row| row[:label] }).to eq([
      "See events", "Create, edit & publish events", "Edit event page content only",
      "Cancel an event (with refunds)", "Copy/repeat events", "Ticket types & prices", "Seating",
      "See attendee names & emails", "Guest list, waitlist & resend tickets", "Door sales", "Scan tickets",
      "Undo a check-in", "Issue refunds", "Finance reports & sales exports", "Finalize settlements",
      "Request payouts", "Payout & W-9 details", "Promo codes, promoters & buyer emails",
      "Invite/remove team members & change roles", "Assign staff to events",
      "Organization profile & verification", "Transfer ownership", "View activity log (all / events / money)"
    ])
    expect(OrganizationRoles::LABELS.keys).to match_array(OrganizationAuthorization::PERMISSIONS.keys.map(&:to_s))
  end

  it "preserves manager, finance, marketer and scanner limits" do
    expect(values("cancel")).to include("owner" => "Yes", "manager" => "No", "finance" => "No")
    %w[refunds settlements payouts].each do |key|
      expect(values(key)).to include("owner" => "Yes", "manager" => "No", "finance" => "Yes")
    end
    expect(values("payout_details")).to include("owner" => "Yes", "finance" => "No")
    expect(values("contacts")).to include("finance" => "Refunds & finance exports", "marketer" => "No",
      "scanner" => "Names only · assigned events")
    expect(values("reports")).to include("box_office" => "Attendee exports only · assigned events", "scanner" => "No")
    expect(values("content")).to include("marketer" => "Yes")
    expect(values("manage_events")).to include("marketer" => "No")
    expect(values("scan")).to include("scanner" => "Assigned events")
    expect(values("reverse")).to include("box_office" => "Assigned events", "scanner" => "No")
  end

  it "limits door roles to assigned events and distinguishes event-only managers" do
    expect(values("events")).to include("manager" => "Yes", "box_office" => "Assigned events", "scanner" => "Assigned events")
    expect(described_class.data[:notes]["scope"]).to include("Event managers have access to their assigned events only")
    expect(described_class.data[:rows].find { |row| row[:key] == "copy" }[:note]).to include("assignments do not allow")
    expect(described_class.data[:notes]["assignments"]).to eq(OrganizationRoles::EVENT_ASSIGNMENT_DESCRIPTION)
    expect(described_class.data[:notes]["offline"]).to include("up to 24 hours")
  end

  it "derives changed grants rather than maintaining an independent allowlist" do
    changed = OrganizationAuthorization::PERMISSIONS.transform_values(&:dup)
    changed[:owner].delete(:refund)
    changed[:manager].delete(:manage_inventory)
    stub_const("OrganizationAuthorization::PERMISSIONS", changed)

    expect(values("cancel")["owner"]).to eq("No")
    expect(values("refunds")["owner"]).to eq("No")
    expect(values("inventory")["manager"]).to eq("No")
    expect(values("seating")["manager"]).to eq("No")
  end

  it "derives activity categories from the parent-owned permission grants" do
    changed = OrganizationAuthorization::PERMISSIONS.transform_values(&:dup)
    changed[:owner] |= %i[view_activity_all view_activity_events view_activity_finance]
    changed[:manager] |= %i[view_activity_events]
    changed[:finance] |= %i[view_activity_finance]
    stub_const("OrganizationAuthorization::PERMISSIONS", changed)

    expect(values("activity")).to eq("owner" => "All activity", "manager" => "Event activity, without payment amounts", "finance" => "Money",
      "marketer" => "No", "box_office" => "No", "scanner" => "No")
  end
end
