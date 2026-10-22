require "rails_helper"

RSpec.describe ApprovedImageUrl do
  let(:profile) { create(:organizer_profile) }
  let(:event) { create(:event, organizer_profile: profile) }
  let(:url) { "https://storage.invalid/uploads/events/photo.webp" }

  before do
    allow(S3Service).to receive(:public_asset_host).and_return("storage.invalid")
  end

  it "accepts a completed upload for the same organization across all image fields" do
    ImageUploadReceipt.create!(user: profile.user, organization: profile.organization, event: event,
      source_key: "pending/photo", final_key: "uploads/events/photo.webp", public_url: url,
      completed_at: Time.current)
    expect(profile.update(logo_url: url)).to be(true)
    expect(event.update(cover_image_url: url, page_customization: {
      gallery: [{ url: url, alt: "Stage" }],
      sections: [{ type: "lineup", enabled: true, items: [{ name: "Mia", photo_url: url }] },
        { type: "sponsors", enabled: true, items: [{ name: "Partner", logo_url: url }] }]
    })).to be(true)
  end

  it "rejects off-host, spoofed, pending, and other-organization images with clear errors" do
    receipt = ImageUploadReceipt.create!(user: profile.user, organization: profile.organization,
      source_key: "pending/photo", final_key: "uploads/events/photo.webp", public_url: url)
    [url, "https://storage.invalid.evil.test/uploads/photo.webp", "https://evil.test/pixel.webp"].each do |candidate|
      expect(profile.update(logo_url: candidate)).to be(false)
      expect(profile.errors.full_messages.join).to include("completed HåfaPass image upload")
      expect(event.update(cover_image_url: candidate)).to be(false)
      expect(event.errors.full_messages.join).to include("completed HåfaPass image upload")
    end
    receipt.update!(completed_at: Time.current)
    receipt.update!(organization: create(:organization))
    expect(event.update(page_customization: { gallery: [{ url: url, alt: "Stage" }] })).to be(false)
    expect(event.errors.full_messages.join).to include("completed HåfaPass image upload")
  end
end
