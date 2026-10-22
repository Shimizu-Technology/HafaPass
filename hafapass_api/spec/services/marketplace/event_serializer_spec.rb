require "rails_helper"

RSpec.describe Marketplace::EventSerializer do
  let(:event) { create(:event, :published, title: "Sunset Fiesta", short_description: "Music by the bay") }
  let!(:ticket_type) { create(:ticket_type, event: event, name: "General Admission", description: "Lawn seating") }

  before do
    with_locales_enabled(%w[en ko], machine_translation: true)
    [event, ticket_type].each do |record|
      record.update_columns(translations: record.translatable_field_names.index_with { |field|
        { "_digest" => Translatable.digest(record[field]), "ko" => "ko:#{record[field]}" }
      })
    end
  end

  it "returns translated marketplace content with the English originals" do
    body = described_class.call(event, locale: "ko")

    expect(body).to include(title: "ko:Sunset Fiesta", short_description: "ko:Music by the bay",
      content_locale: "ko", machine_translated: true)
    expect(body[:original_content]).to include("title" => "Sunset Fiesta")
    expect(body[:ticket_types].first).to include(name: "ko:General Admission", description: "ko:Lawn seating",
      machine_translated: true, original_name: "General Admission", original_description: "Lawn seating")
  end

  it "keeps English by default and when the requested language is disabled" do
    expect(described_class.call(event)).to include(title: "Sunset Fiesta", content_locale: "en",
      machine_translated: false, original_content: nil)

    with_locales_enabled(%w[en], machine_translation: true)
    expect(described_class.call(event, locale: "ko")).to include(title: "Sunset Fiesta", content_locale: "en",
      machine_translated: false, original_content: nil)
  end

  it "limits marketplace card design to focal point and accent" do
    event.update!(page_customization: { accent: "#123456", focal_point: { x: 20, y: 60 },
      sections: [{ type: "faq", enabled: true, items: [{ question: "When?", answer: "Tonight" }] }] })
    expect(described_class.call(event)[:page_customization]).to eq("accent" => "#123456",
      "focal_point" => { "x" => 20, "y" => 60 })
  end
end
