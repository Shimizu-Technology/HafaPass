# frozen_string_literal: true

require "rails_helper"

RSpec.describe PaymentReadinessReview do
  let(:account) { create(:connected_account, with_readiness_approval: false) }
  let(:submitter) { create(:user, :admin) }
  let(:approver) { create(:user, :admin) }
  let(:submission) { create(:payment_readiness_review, :submission, connected_account: account, actor_user: submitter) }

  it "enforces independent approval even outside the workflow service" do
    review = build(:payment_readiness_review, :approval, connected_account: account,
      parent_review: submission, actor_user: submitter,
      **PaymentReadinessReviews::Manager.send(:snapshot, submission))

    expect(review).not_to be_valid
    expect(review.errors.full_messages).to include(/independent from the evidence submitter/)
  end

  it "rejects an approval whose evidence differs from its submission" do
    review = build(:payment_readiness_review, :approval, connected_account: account,
      parent_review: submission, actor_user: approver,
      **PaymentReadinessReviews::Manager.send(:snapshot, submission).merge(
        liability_schedule_reference: "different-liability-decision"
      ))

    expect(review).not_to be_valid
    expect(review.errors.full_messages).to include(/Evidence snapshot must match/)
  end

  it "requires revocation reasons and prevents duplicate revocations in the database" do
    approval = create(:payment_readiness_review, :approval, connected_account: account,
      parent_review: submission, actor_user: approver,
      **PaymentReadinessReviews::Manager.send(:snapshot, submission))
    invalid = build(:payment_readiness_review, :revocation, connected_account: account,
      parent_review: approval, actor_user: submitter, reason: nil,
      **PaymentReadinessReviews::Manager.send(:snapshot, approval))
    expect(invalid).not_to be_valid
    expect(invalid.errors.full_messages).to include(/Reason is required/)

    create(:payment_readiness_review, :revocation, connected_account: account,
      parent_review: approval, actor_user: submitter,
      **PaymentReadinessReviews::Manager.send(:snapshot, approval))
    duplicate = build(:payment_readiness_review, :revocation, connected_account: account,
      parent_review: approval, actor_user: approver,
      **PaymentReadinessReviews::Manager.send(:snapshot, approval))
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "requires a reason for a rejection" do
    rejection = build(:payment_readiness_review, :rejection, connected_account: account,
      parent_review: submission, actor_user: approver, reason: nil,
      **PaymentReadinessReviews::Manager.send(:snapshot, submission))

    expect(rejection).not_to be_valid
    expect(rejection.errors.full_messages).to include(/Reason is required/)
  end
end
