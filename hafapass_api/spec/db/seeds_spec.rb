require "rails_helper"

RSpec.describe "db/seeds.rb" do
  def load_seeds
    expect { load Rails.root.join("db/seeds.rb") }.to output(/Seeding complete!/).to_stdout
  end

  it "seeds organizations, owner memberships and Guam-local events, and can be re-run" do
    load_seeds
    load_seeds

    expect(Organization.count).to eq(5)
    expect(OrganizerProfile.count).to eq(5)
    expect(Event.count).to eq(10)

    OrganizerProfile.includes(:organization, :user).find_each do |profile|
      membership = OrganizationMembership.find_by!(organization: profile.organization, user: profile.user)
      expect(membership).to be_owner
      expect(membership).to be_effective
    end

    Event.includes(:organizer_profile).find_each do |event|
      expect(event.organization_id).to eq(event.organizer_profile.organization_id)
    end

    concert = Event.find_by!(title: "Hafaloha Concert Series Part 5: featuring J Boog")
    local_start = concert.starts_at.in_time_zone("Pacific/Guam")
    expect([local_start.hour, local_start.min]).to eq([17, 0])
  end
end
