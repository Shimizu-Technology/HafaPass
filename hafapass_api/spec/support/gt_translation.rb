# Specs never reach General Translation: credentials in a developer's
# environment are ignored unless a spec opts in with `with_gt_credentials`,
# and that spec must stub the HTTP call.
module GtTranslationHelpers
  def with_gt_credentials
    stub_const("ENV", ENV.to_h.merge("GT_API_KEY" => "test-key", "GT_PROJECT_ID" => "test-project"))
    allow(GtTranslationService).to receive(:configured?).and_call_original
  end
end

RSpec.configure do |config|
  config.include GtTranslationHelpers
  config.before { allow(GtTranslationService).to receive(:configured?).and_return(false) }
end
