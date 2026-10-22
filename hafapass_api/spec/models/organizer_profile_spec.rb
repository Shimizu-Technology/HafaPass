require 'rails_helper'

RSpec.describe OrganizerProfile, type: :model do
  describe "validations" do
    it "rechecks an existing logo when the organization changes" do
      profile = create(:organizer_profile)
      logo = "https://storage.invalid/uploads/logo.webp"
      ImageUploadReceipt.create!(user: profile.user, organization: profile.organization,
        source_key: "pending/logo", final_key: "uploads/logo.webp", public_url: logo, completed_at: Time.current)
      profile.update!(logo_url: logo)
      profile.organization = create(:organization)

      expect(profile).not_to be_valid
      expect(profile.errors[:logo_url]).to include(ApprovedImageUrl::MESSAGE)
    end
    it "is valid with valid attributes" do
      profile = build(:organizer_profile)
      expect(profile).to be_valid
    end

    it "requires business_name" do
      profile = build(:organizer_profile, business_name: nil)
      expect(profile).not_to be_valid
      expect(profile.errors[:business_name]).to include("can't be blank")
    end

    it "allows only one organization profile per user" do
      user = create(:user, :organizer)
      create(:organizer_profile, user: user)

      expect(build(:organizer_profile, user: user)).not_to be_valid
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
