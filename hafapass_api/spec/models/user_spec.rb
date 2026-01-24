require 'rails_helper'

RSpec.describe User, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      user = build(:user)
      expect(user).to be_valid
    end

    it "requires clerk_id" do
      user = build(:user, clerk_id: nil)
      expect(user).not_to be_valid
      expect(user.errors[:clerk_id]).to include("can't be blank")
    end

    it "requires clerk_id to be unique" do
      create(:user, clerk_id: "clerk_unique_1")
      user = build(:user, clerk_id: "clerk_unique_1")
      expect(user).not_to be_valid
      expect(user.errors[:clerk_id]).to include("has already been taken")
    end
  end

  describe "role enum" do
    it "defaults to attendee" do
      user = User.new
      expect(user.attendee?).to be true
    end

    it "can be set to organizer" do
      user = build(:user, :organizer)
      expect(user.organizer?).to be true
    end

    it "can be set to admin" do
      user = build(:user, :admin)
      expect(user.admin?).to be true
    end

    it "provides role query methods" do
      user = create(:user, role: :attendee)
      expect(user.attendee?).to be true
      expect(user.organizer?).to be false
      expect(user.admin?).to be false
    end
  end

  describe "associations" do
    it "has one organizer_profile" do
      user = create(:user, :organizer)
      profile = create(:organizer_profile, user: user)
      expect(user.reload.organizer_profile).to eq(profile)
    end

    it "has many orders" do
      user = create(:user)
      event = create(:event, :published)
      order = create(:order, user: user, event: event)
      expect(user.orders).to include(order)
    end

    it "destroys organizer_profile when destroyed" do
      user = create(:user, :organizer)
      create(:organizer_profile, user: user)
      expect { user.destroy }.to change(OrganizerProfile, :count).by(-1)
    end

    it "nullifies orders when destroyed" do
      user = create(:user)
      event = create(:event, :published)
      order = create(:order, user: user, event: event)
      user.destroy
      expect(order.reload.user_id).to be_nil
    end
  end
end
