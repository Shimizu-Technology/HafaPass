require 'rails_helper'

RSpec.describe OrganizerProfile, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      profile = build(:organizer_profile)
      expect(profile).to be_valid
    end

    it "requires business_name" do
      profile = build(:organizer_profile, business_name: nil)
      expect(profile).not_to be_valid
      expect(profile.errors[:business_name]).to include("can't be blank")
    end
  end

  describe "associations" do
    it "belongs to user" do
      user = create(:user, :organizer)
      profile = create(:organizer_profile, user: user)
      expect(profile.user).to eq(user)
    end

    it "has many events" do
      profile = create(:organizer_profile)
      event = create(:event, organizer_profile: profile)
      expect(profile.events).to include(event)
    end
  end
end
