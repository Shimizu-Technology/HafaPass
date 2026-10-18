require "rails_helper"

RSpec.describe ClerkProfileSync do
  let(:user) { create(:user, role: :support, email: nil, first_name: nil, last_name: nil) }
  let(:profile) { { email: "verified@example.test", first_name: "Jane", last_name: "Doe" } }
  before { allow(ClerkIdentity).to receive(:profile).with(user.clerk_id).and_return(profile) }

  it "backfills missing display data without changing role or subject" do
    described_class.call(user)
    expect(user.attributes).to include("email" => "verified@example.test", "first_name" => "Jane", "last_name" => "Doe", "role" => "support")
    expect(user.clerk_profile_checked_at).to be_present
  end

  it "preserves independently editable contact fields" do
    user.update!(email: "contact@example.test", first_name: "Preferred", last_name: "Name")
    described_class.call(user)
    expect(user.attributes).to include("email" => "contact@example.test", "first_name" => "Preferred", "last_name" => "Name")
    expect(user.reload.clerk_profile_checked_at).to be_nil
    expect(ClerkIdentity).not_to have_received(:profile)
  end

  it "bounds provider calls across distinct model instances, and refreshes after expiry" do
    allow(ClerkIdentity).to receive(:profile).and_return(profile.merge(last_name: nil))
    described_class.call(user)
    described_class.call(User.find(user.id))
    expect(ClerkIdentity).to have_received(:profile).once
    user.update!(clerk_profile_checked_at: 6.minutes.ago)
    described_class.call(user)
    expect(ClerkIdentity).to have_received(:profile).twice
  end

  it "stops looking up a complete profile even after the lease expires" do
    described_class.call(user)
    user.update!(clerk_profile_checked_at: 6.minutes.ago)
    described_class.call(User.find(user.id))
    expect(ClerkIdentity).to have_received(:profile).once
  end

  it "retains saved fields on outages and bounds retry attempts" do
    user.update!(first_name: "Saved")
    allow(ClerkIdentity).to receive(:profile).and_return(nil)
    2.times { described_class.call(User.find(user.id)) }
    expect(user.reload.first_name).to eq("Saved")
    expect(user.email).to be_nil
    expect(ClerkIdentity).to have_received(:profile).once
  end

  it "never replaces a contact edit made during the provider lookup" do
    allow(ClerkIdentity).to receive(:profile) do
      User.find(user.id).update!(email: "concurrent@example.test")
      profile
    end
    described_class.call(user)
    expect(user.email).to eq("concurrent@example.test")
    expect(user.first_name).to eq("Jane")
  end

  it "does not write a late response after a newer lookup acquired the lease" do
    allow(ClerkIdentity).to receive(:profile) do
      User.find(user.id).update!(clerk_profile_checked_at: 1.minute.from_now)
      profile
    end
    described_class.call(user)
    expect(user.email).to be_nil
    expect(user.first_name).to be_nil
  end

  it "keeps absent provider fields from erasing existing data" do
    user.update!(email: "saved@example.test")
    allow(ClerkIdentity).to receive(:profile).and_return({ email: nil, first_name: nil, last_name: nil })
    described_class.call(user)
    expect(user.email).to eq("saved@example.test")
  end
end
