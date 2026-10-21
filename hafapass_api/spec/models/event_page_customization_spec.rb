require "rails_helper"

RSpec.describe Event, type: :model do
  let(:event) { create(:event) }
  let(:image) { "https://storage.invalid/uploads/photo.webp" }

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
    [{ injected: "<script>" }, { accent: "red; color: white" }, { focal_point: { x: "101", y: 10 } }].each do |design|
      expect(accepts?(design)).to be(false)
    end
  end

  it "clamps numeric focal points on the server" do
    event.update!(page_customization: { focal_point: { x: -50, y: 125 } })
    expect(event.reload.page_customization.fetch("focal_point")).to eq("x" => 0, "y" => 100)
  end

  it "does not revalidate legacy design data when saving unrelated lifecycle state" do
    event.update_columns(page_customization: { accent: "legacy-invalid" })
    expect { event.reload.update!(status: :cancelled) }.not_to raise_error
    expect(event.reload.page_customization).to eq("accent" => "legacy-invalid")
  end

  it "checks all image receipts in one query" do
    other = "https://storage.invalid/uploads/other.webp"
    ImageUploadReceipt.create!(user: event.organizer_profile.user, organization: event.organization,
      event: event, source_key: "pending/test/other", final_key: "uploads/test/other.webp",
      public_url: other, completed_at: Time.current)
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) {
      queries << payload[:sql] if payload[:sql]&.include?("FROM \"image_upload_receipts\"")
    }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      expect(accepts?({ gallery: [{ url: image, alt: "Stage" }, { url: other, alt: "Crowd" }],
        sections: [{ type: "lineup", enabled: true, items: [{ name: "Band", photo_url: image }] }] })).to be(true)
    end
    expect(queries.size).to eq(1)
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

  it "accepts a cleared optional lineup or sponsor link" do
    expect(accepts?({ sections: [{ type: "lineup", enabled: true,
      items: [{ name: "Mia", url: "" }] },
      { type: "sponsors", enabled: true, items: [{ name: "Partner", logo_url: image, url: "" }] }] })).to be(true)
  end

  it "names each invalid page field without blaming unrelated image URLs" do
    cases = [
      [{ accent: "red" }, /accent must be a six-digit hex color/],
      [{ focal_point: { x: "50", y: 20 } }, /focal point/],
      [{ description_format: "html" }, /description format/],
      [{ gallery: [{ url: image, alt: "Stage" }, { url: image, alt: " " }] }, /gallery photo 2 needs alt text/],
      [{ gallery: Array.new(9) { { url: image, alt: "Stage" } } }, /at most 8 photos/],
      [{ sections: [{ type: "video", enabled: true, url: "https://example.invalid/watch" }] }, /video URL/],
      [{ sections: [{ type: "links", enabled: true, items: [{ label: "Bad", kind: "website", url: "javascript:alert(1)" }] }] }, /unsafe link/],
      [{ sections: [{ type: "faq", enabled: true, items: Array.new(21) { { question: "Q", answer: "A" } } }] }, /at most 20 items/]
    ]
    cases.each do |design, message|
      expect(accepts?(design)).to be(false)
      expect(event.errors.full_messages.join(" ")).to match(message)
      expect(event.errors.full_messages.join(" ")).not_to include(ApprovedImageUrl::MESSAGE)
    end
    expect(accepts?({ gallery: [{ url: "https://example.invalid/unverified.webp", alt: "Stage" }] })).to be(false)
    expect(event.errors.full_messages.join(" ")).to include(ApprovedImageUrl::MESSAGE)
  end
end
