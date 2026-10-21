require "rails_helper"

RSpec.describe Event, type: :model do
  let(:event) { create(:event) }
  let(:image) { "https://example.invalid/photo.webp" }

  before do
    ImageUploadReceipt.create!(user: event.organizer_profile.user, organization: event.organization,
      event: event, source_key: "pending/test/image", final_key: "uploads/test/image.webp",
      public_url: image, completed_at: Time.current)
  end

  def accepts?(design)
    event.page_customization = design
    event.valid?
    event.errors[:page_customization].empty?
  end

  it "accepts a bounded complete page design" do
    expect(accepts?({ accent: "#123456", focal_point: { x: 25, y: 75 }, description_format: "markdown",
      gallery: [{ url: image, alt: "Dancers on stage", caption: "Opening night" }],
      sections: [{ type: "gallery", enabled: true, items: [] },
        { type: "lineup", enabled: true, items: [{ name: "Performer", photo_url: image }] },
        { type: "video", enabled: true, url: "https://www.youtube.com/watch?v=abcdefghijk" }] })).to be(true)
  end

  it "rejects unknown fields, malformed colors and out-of-range focal points" do
    [{ injected: "<script>" }, { accent: "red; color: white" }, { focal_point: { x: 101, y: 10 } }].each do |design|
      expect(accepts?(design)).to be(false)
    end
  end

  it "limits galleries, requires alt text and bounds JSON size" do
    expect(accepts?({ gallery: Array.new(9) { { url: image, alt: "Photo" } } })).to be(false)
    expect(accepts?({ gallery: [{ url: image, alt: " " }] })).to be(false)
    expect(accepts?({ gallery: [{ url: image, alt: "x" * 33_000 }] })).to be(false)
    expect(accepts?({ gallery: [{ url: "https://example.invalid/unverified.webp", alt: "Unverified" }] })).to be(false)
  end

  it "rejects script and insecure links, spoofed video hosts and duplicate sections" do
    expect(accepts?({ sections: [{ type: "links", enabled: true,
      items: [{ label: "Bad", kind: "website", url: "javascript:alert(1)" }] }] })).to be(false)
    expect(accepts?({ sections: [{ type: "lineup", enabled: true,
      items: [{ name: "Bad", url: "http://example.invalid" }] }] })).to be(false)
    expect(accepts?({ sections: [{ type: "video", enabled: true,
      url: "https://youtube.com.evil.invalid/watch?v=abcdefghijk" }] })).to be(false)
    expect(accepts?({ sections: Array.new(2) { { type: "faq", enabled: false, items: [] } } })).to be(false)
  end
end
