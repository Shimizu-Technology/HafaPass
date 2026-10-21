# Specs never reach General Translation: credentials or switches in a
# developer's environment are ignored unless a spec opts in, and a spec that
# opts in with `with_gt_credentials` must stub the HTTP call.
module GtTranslationHelpers
  # Buyer languages the server answers in (HAFAPASS_ENABLED_LOCALES), and
  # optionally the machine translation switch, without credentials.
  def with_locales_enabled(codes = AppLocale::SUPPORTED, machine_translation: false)
    stub_const("ENV", ENV.to_h.merge("HAFAPASS_ENABLED_LOCALES" => Array(codes).join(","),
      "HAFAPASS_MACHINE_TRANSLATION" => machine_translation.to_s))
    use_configured_switches
  end

  def with_gt_credentials(machine_translation: true)
    stub_const("ENV", ENV.to_h.merge("GT_API_KEY" => "test-key", "GT_PROJECT_ID" => "test-project",
      "HAFAPASS_ENABLED_LOCALES" => AppLocale::SUPPORTED.join(","), "HAFAPASS_MACHINE_TRANSLATION" => machine_translation.to_s))
    allow(GtTranslationService).to receive(:configured?).and_call_original
    use_configured_switches
  end

  def use_configured_switches
    allow(AppLocale).to receive(:enabled).and_call_original
    allow(AppLocale).to receive(:machine_translation_enabled?).and_call_original
  end
end

RSpec.configure do |config|
  config.include GtTranslationHelpers
  config.before do
    allow(GtTranslationService).to receive(:configured?).and_return(false)
    allow(AppLocale).to receive(:enabled).and_return([AppLocale::DEFAULT])
    allow(AppLocale).to receive(:machine_translation_enabled?).and_return(false)
  end
end
