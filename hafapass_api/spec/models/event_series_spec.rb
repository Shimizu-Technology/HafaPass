# frozen_string_literal: true

require "rails_helper"

RSpec.describe EventSeries, type: :model do
  let(:organization) { create(:organization) }
  let(:other_organization) { create(:organization) }

  describe "slug normalization and uniqueness" do
    it "auto-generates a lowercase kebab-case slug from name when blank" do
      series = create(:event_series, organization: organization, name: "FD Alumni Basketball Tournament 2026", slug: nil)
      expect(series.slug).to eq("fd-alumni-basketball-tournament-2026")
    end

    it "deduplicates auto-generated slugs within the same organization" do
      first = create(:event_series, organization: organization, name: "Island Cup", slug: nil)
      second = create(:event_series, organization: organization, name: "Island Cup", slug: nil)
      expect(first.slug).to eq("island-cup")
      expect(second.slug).to eq("island-cup-2")
    end

    it "normalizes a provided slug and allows the same slug in a different organization" do
      first = create(:event_series, organization: organization, name: "Cup A", slug: "FD Tourney 2026")
      second = create(:event_series, organization: other_organization, name: "Cup B", slug: "fd-tourney-2026")
      expect(first.slug).to eq("fd-tourney-2026")
      expect(second).to be_persisted
    end

    it "rejects duplicate slugs in the same organization" do
      create(:event_series, organization: organization, slug: "summer-jam")
      duplicate = build(:event_series, organization: organization, slug: "summer-jam")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end
  end

  describe "revenue share validations" do
    it "allows nil or 0..10000 for revenue_share_bps" do
      expect(build(:event_series, organization: organization, revenue_share_bps: nil)).to be_valid
      expect(build(:event_series, organization: organization, revenue_share_bps: 0)).to be_valid
      expect(build(:event_series, organization: organization, revenue_share_bps: 5000)).to be_valid
      expect(build(:event_series, organization: organization, revenue_share_bps: 10_000)).to be_valid
      expect(build(:event_series, organization: organization, revenue_share_bps: -1)).not_to be_valid
      expect(build(:event_series, organization: organization, revenue_share_bps: 10_001)).not_to be_valid
    end

    it "validates revenue_share_base inclusion" do
      expect(build(:event_series, organization: organization, revenue_share_base: "admissions_gross")).to be_valid
      expect(build(:event_series, organization: organization, revenue_share_base: "invalid_base")).not_to be_valid
    end
  end

  describe "EventSeriesMembership" do
    let!(:organizer_profile) { create(:organizer_profile, organization: organization) }
    let!(:other_profile) { create(:organizer_profile, organization: other_organization) }
    let(:series) { create(:event_series, organization: organization) }
    let(:event) { create(:event, organizer_profile: organizer_profile, organization: organization) }
    let(:other_event) { create(:event, organizer_profile: other_profile, organization: other_organization) }

    it "rejects events from another organization" do
      membership = build(:event_series_membership, event_series: series, event: other_event)
      expect(membership).not_to be_valid
      expect(membership.errors[:event]).to include("must belong to the same organization as the event series")
    end

    it "enforces uniqueness of event per series and orders memberships by position then id" do
      event2 = create(:event, organizer_profile: organizer_profile, organization: organization)
      m2 = series.event_series_memberships.create!(event: event2, role: :championship_night, position: 2)
      m1 = series.event_series_memberships.create!(event: event, role: :regular_night, position: 1)

      duplicate = series.event_series_memberships.build(event: event, role: :other, position: 3)
      expect(duplicate).not_to be_valid
      expect(series.event_series_memberships.reload.to_a).to eq([m1, m2])
    end

    it "records audit logs for series CRUD and membership changes" do
      series.update!(status: :active)
      membership = series.event_series_memberships.create!(event: event, role: :regular_night, position: 0)
      membership.destroy!
      series.destroy!

      actions = AuditLog.where(organization: organization).pluck(:action)
      expect(actions).to include(
        "event_series.created",
        "event_series.updated",
        "event_series.event_added",
        "event_series.event_removed",
        "event_series.deleted"
      )
    end
  end
end
