require "rails_helper"

RSpec.describe StripeProcessingFeeJob, type: :job, non_transactional: true do
  self.use_transactional_tests = false
  before do
    raise "Fee job specs must only run in test" unless Rails.env.test?
    clean_test_data
  end
  after { clean_test_data }
  let(:payment) { create(:payment, :succeeded) }

  it "persists the recovery row and enqueues source-scoped reconciliation after capture" do
    expect { StripeProcessingFees.request!(payment) }.to have_enqueued_job(described_class).with(payment.id)
    expect(StripeFeeEvidence.find_by!(payment: payment)).to be_status_pending
  end

  it "does not enqueue work or persist fee evidence for a rolled back capture transaction" do
    capture = payment
    expect do
      Payment.transaction do
        StripeProcessingFees.request!(capture)
        raise ActiveRecord::Rollback
      end
    end.not_to have_enqueued_job(described_class)
    expect(StripeFeeEvidence.find_by(payment: capture)).to be_nil
  end

  it "keeps a durable pending row and schedules retry when the provider evidence is unavailable" do
    allow(StripeService).to receive(:retrieve_fee_payment_intent).and_raise(Stripe::APIConnectionError, "unavailable")
    expect { described_class.perform_now(payment.id) }.to have_enqueued_job(described_class)
    row = StripeFeeEvidence.find_by!(payment: payment)
    expect(row).to be_status_pending
    expect(row.next_attempt_at).to be_future
  end

  it "recovers missing queue entries from database evidence without executing any provider request in the sweep" do
    payment
    expect { SweepPendingStripeFeesJob.perform_now }.to have_enqueued_job(described_class).with(payment.id)
    expect(StripeFeeEvidence.find_by!(payment: payment)).to be_status_pending
  end

  it "preserves durable evidence and the caller result when the queue is unavailable" do
    allow(described_class).to receive(:perform_later).and_raise(IOError, "queue unavailable")
    expect { StripeProcessingFees.request!(payment) }.not_to raise_error
    evidence = StripeFeeEvidence.find_by!(payment: payment)
    expect(evidence).to be_status_pending
    expect(evidence.last_error_code).to eq("fee_queue_unavailable")
  end

  it "never schedules simulated or cash captures" do
    simulated = create(:payment, :succeeded, provider_payment_id: "sim_pi_fixture")
    cash = create(:payment, :succeeded, provider: "door_cash")
    expect do
      StripeProcessingFees.request!(simulated)
      StripeProcessingFees.request!(cash)
      SweepPendingStripeFeesJob.perform_now
    end.not_to have_enqueued_job(described_class)
  end
  def clean_test_data
    ActiveRecord::Base.connection.execute("TRUNCATE TABLE users, organizer_profiles, events, site_settings, webhook_events RESTART IDENTITY CASCADE")
  end
end
