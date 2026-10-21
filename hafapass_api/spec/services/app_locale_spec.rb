require "rails_helper"

RSpec.describe AppLocale do
  it "maps language tags to the supported codes" do
    expect(%w[en en-US ko ko-KR ja ja_JP tl fil fil-PH].map { |tag| described_class.normalize(tag) })
      .to eq(%w[en en ko ko ja ja tl tl tl])
    expect(%w[zh zh-CN zh-Hans zh-SG zh-Hans-TW].map { |tag| described_class.normalize(tag) }).to all(eq("zh"))
    expect(%w[zh-Hant zh-TW zh-HK zh_mo zh-Hant-CN].map { |tag| described_class.normalize(tag) }).to all(eq("zh-Hant"))
    expect([nil, "", "fr", "ch", "*", { "x" => 1 }].map { |tag| described_class.normalize(tag) }).to all(be_nil)
  end

  it "prefers ?locale=, then the highest-weighted supported Accept-Language, then English" do
    with_locales_enabled
    expect(described_class.resolve(param: "ja", accept_language: "ko")).to eq("ja")
    expect(described_class.resolve(accept_language: "fr-FR, zh-TW;q=0.8, ko;q=0.9")).to eq("ko")
    expect(described_class.resolve(accept_language: "fr, de;q=0.5")).to eq("en")
    expect(described_class.resolve(accept_language: "ko;q=0, ja;q=0.2")).to eq("ja")
    expect(described_class.resolve(param: "xx", accept_language: nil)).to eq("en")
  end

  it "answers only in enabled languages, English by default, and keeps machine translation off by default" do
    use_configured_switches
    expect(described_class.enabled).to eq(%w[en])
    expect(described_class.resolve(param: "ko", accept_language: "ja")).to eq("en")
    expect(described_class).not_to be_machine_translation_enabled

    with_locales_enabled(%w[ja zh-TW bogus], machine_translation: true)
    expect(described_class.enabled).to eq(%w[en ja zh-Hant])
    expect(described_class.resolve(param: "ko", accept_language: "ko, ja;q=0.5")).to eq("ja")
    expect(described_class).to be_machine_translation_enabled
  end

  it "reads unknown stored codes as English and maps Filipino for General Translation" do
    expect(described_class.i18n_locale("zh-Hant")).to eq(:"zh-Hant")
    expect(described_class.i18n_locale("ch")).to eq(:en)
    expect(described_class.gt_code("tl")).to eq("fil")
    expect(described_class.gt_code("ko")).to eq("ko")
  end
end
