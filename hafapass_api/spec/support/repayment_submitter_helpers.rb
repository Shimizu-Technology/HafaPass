# frozen_string_literal: true

# A1-R1 ships Commerce::BuyerRepayment::SUBMITTER_ACTIVE = false, and every
# spec runs as R1 by default. `repayment_submitter: :active` runs an example
# as A1-R2, whose only change is that constant (design §10.1), by stubbing
# the one reader of it.
RSpec.configure do |config|
  config.before(:each, repayment_submitter: :active) do
    allow(Commerce::BuyerRepayment).to receive(:submitter_active?).and_return(true)
  end
end
