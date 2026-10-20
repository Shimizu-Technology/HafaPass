require "rails_helper"

RSpec.describe "Event translated content" do
  let(:event) do
    create(:event, title: "Sunset Fiesta", short_description: "Music by the bay", description: "Bring a chair",
      supported_locales: %w[en ja])
  end

  def machine_translate!(record, fields, locales = AppLocale::TRANSLATION_TARGETS)
    translations = fields.to_h do |field|
      [field, locales.index_with { |locale| "#{locale}:#{record[field]}" }.merge("_digest" => Translatable.digest(record[field]))]
    end
    record.update_columns(translations: translations, translation_status: "translated")
  end

  it "uses the organizer's translation, then a current machine translation, then English" do
    machine_translate!(event, %w[title short_description description])
    event.update!(localized_content: { "ja" => { "title" => "サンセット・フィエスタ" } })

    expect(event.content_for("ja")).to include(title: "サンセット・フィエスタ", short_description: "ja:Music by the bay",
      locale: "ja", machine_translated: true)
    expect(event.content_for("ko-KR")).to include(title: "ko:Sunset Fiesta", locale: "ko", machine_translated: true)
    expect(event.content_for("zh-TW")).to include(title: "zh-Hant:Sunset Fiesta", locale: "zh-Hant")
    expect(event.content_for("en")).to include(title: "Sunset Fiesta", machine_translated: false)
    expect(event.content_for("fr")).to include(title: "Sunset Fiesta", locale: "en")
  end

  it "only uses organizer content for languages the organizer enabled" do
    event.update!(localized_content: { "ko" => { "title" => "선셋 피에스타" } })
    expect(event.content_for("ko")[:title]).to eq("Sunset Fiesta")

    event.update!(supported_locales: %w[en ko])
    expect(event.content_for("ko")).to include(title: "선셋 피에스타", machine_translated: false)
  end

  it "falls back to English when the English changed after it was translated" do
    machine_translate!(event, %w[title])
    event.update_columns(title: "Sunrise Fiesta")

    expect(event.content_for("ko")).to include(title: "Sunrise Fiesta", machine_translated: false)
  end

  it "accepts organizer content for every buyer language and keeps existing CHamoru content valid" do
    event.supported_locales = %w[en ko ja zh-Hant zh tl ch]
    event.localized_content = { "zh-Hant" => { "title" => "日落節" }, "ch" => { "title" => "Fiestan Puesta" } }
    expect(event).to be_valid

    event.supported_locales = %w[en fr]
    event.localized_content = { "fr" => { "title" => "Fête" } }
    expect(event).not_to be_valid
    expect(event.errors[:supported_locales]).to include("contains an unsupported locale")
    expect(event.errors[:localized_content]).to include("may only contain supported languages")
  end

  it "does not queue anything without General Translation credentials" do
    expect { event.update!(title: "New title") }.not_to have_enqueued_job(TranslateRecordJob)
    expect(event.reload.translation_status).to eq("untranslated")
    expect(event.retranslate!).to be(false)
  end
end
