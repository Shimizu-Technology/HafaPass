require "rails_helper"

RSpec.describe ApplicationJob do
  it "defers enqueueing until the surrounding database transaction commits" do
    expect(described_class.enqueue_after_transaction_commit).to be(true)
  end

  it "does not enqueue a job from a rolled-back transaction" do
    stub_const("TransactionAwareTestJob", Class.new(ApplicationJob) do
      def perform; end
    end)

    expect do
      ApplicationRecord.transaction do
        TransactionAwareTestJob.perform_later
        raise ActiveRecord::Rollback
      end
    end.not_to have_enqueued_job(TransactionAwareTestJob)
  end
end
