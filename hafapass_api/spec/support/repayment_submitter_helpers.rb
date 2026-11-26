# frozen_string_literal: true

# A1-R2 ships Commerce::BuyerRepayment::SUBMITTER_ACTIVE = true, so specs run
# with the active submitter by default. `repayment_submitter: :inactive`
# exercises the A1-R1 inactive-submitter wait guard, and `:active` stays a
# harmless explicit tag.
RSpec.configure do |config|
  config.before(:each, repayment_submitter: :active) do
    allow(Commerce::BuyerRepayment).to receive(:submitter_active?).and_return(true)
  end

  config.before(:each, repayment_submitter: :inactive) do
    allow(Commerce::BuyerRepayment).to receive(:submitter_active?).and_return(false)
  end
end
