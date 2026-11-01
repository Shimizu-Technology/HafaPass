# StripeService remembers confirmed key -> platform account matches per
# process. Clear them so one example's stubbed account never leaks to another.
RSpec.configure do |config|
  config.before { StripeService.clear_platform_account_cache! }
end
