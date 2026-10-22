# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayoutWithholdingGuard do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let!(:tax) { create(:organizer_tax_information, organization: organization) }
  let(:event) { create(:event, organization: organization) }
  let(:payout) do
    create(:payout, organization: organization, event: event,
      settlement: create(:settlement, organization: organization, event: event),
      connected_account: create(:connected_account, organization: organization),
      amount_cents: 10_000)
  end

  it "blocks a pending payout that became subject to withholding before submission" do
    payout
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    creator = PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
    expect(PayoutGateway).not_to receive(:submit)
    expect { creator.send(:submit_payout!, payout) }.to raise_error(PayoutCreator::PayoutError, /withholding review blocks/)
  end

  it "recalculates withheld and net cents before submission in withhold mode" do
    payout
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    SiteSetting.instance.update!(backup_withholding_mode: "withhold")
    creator = PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
    allow(PayoutGateway).to receive(:submit).with(payout).and_return(:submitted)
    creator.send(:submit_payout!, payout)
    expect(payout.reload).to have_attributes(status: "pending", withheld_cents: 2400)
    expect(payout.disbursement_cents).to eq(7600)
    expect(AuditLog.where(auditable: payout, action: "payout.backup_withholding_recalculated")).to exist
  end

  it "blocks a $100 payout after switching from withhold to block even with $24 already withheld" do
    payout.update!(withheld_cents: 2400, withholding_rate_bps: 2400, withholding_reason: "tin_or_admin_flag")
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    SiteSetting.instance.update!(backup_withholding_mode: "block")

    expect do
      organization.with_lock { payout.with_lock { described_class.call(payout: payout, actor: admin) } }
    end.to raise_error(described_class::WithholdingError, /blocks this payout/)
    expect(payout.reload.disbursement_cents).to eq(7600)
  end

  it "adjusts a stale withhold rate and restores gross when withholding is cleared" do
    payout.update!(withheld_cents: 2400, withholding_rate_bps: 2400, withholding_reason: "tin_or_admin_flag")
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    SiteSetting.instance.update!(backup_withholding_mode: "withhold", backup_withholding_rate_bps: 2000)
    organization.with_lock { payout.with_lock { described_class.call(payout: payout, actor: admin) } }
    expect(payout.reload).to have_attributes(withheld_cents: 2000, withholding_rate_bps: 2000)
    expect(payout.disbursement_cents).to eq(8000)

    tax.update!(backup_withholding_flag: false, backup_withholding_reason: nil)
    organization.with_lock { payout.with_lock { described_class.call(payout: payout, actor: admin) } }
    expect(payout.reload).to have_attributes(withheld_cents: 0, withholding_rate_bps: 0,
      withholding_reason: nil)
    expect(payout.disbursement_cents).to eq(10_000)
    audits = AuditLog.where(auditable: payout, action: "payout.backup_withholding_recalculated").order(:id)
    expect(audits.count).to eq(2)
    expect(audits.last.after_data).to include("withheld_cents" => 0)
  end

  it "keeps a paid provider result immutable and carries the withholding shortfall" do
    payout.update!(status: :processing)
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    SiteSetting.instance.update!(backup_withholding_mode: "withhold")
    creator = PayoutCreator.new(settlement: payout.settlement, actor: admin, idempotency_key: payout.idempotency_key)
    creator.send(:record_submission_outcome!, payout, status: :paid, provider_payout_id: "bank-42",
      initiated_at: Time.current, paid_at: Time.current)
    expect(payout.reload).to have_attributes(status: "paid", withheld_cents: 0,
      under_withheld_cents: 2400)
    expect(AuditLog.where(auditable: payout, action: "payout.under_withholding_carried")).to exist
  end

  it "refuses any amount rewrite after a payout starts processing" do
    payout.update!(status: :processing)
    expect { payout.update!(withheld_cents: 2400) }
      .to raise_error(ActiveRecord::RecordInvalid, /submitted payout.*fixed/)
    expect(payout.reload).to have_attributes(withheld_cents: 0, amount_cents: 10_000)
  end

  it "requires a separate audited admin withholding override and rejects a TIN in it" do
    payout
    tax.update!(backup_withholding_flag: true, backup_withholding_reason: "IRS review")
    organization.with_lock do
      payout.with_lock do
        expect { described_class.call(payout: payout, actor: admin, override_reason: "TIN 012345678 is okay") }
          .to raise_error(described_class::WithholdingError, /This looks like a taxpayer ID/)
        described_class.call(payout: payout, actor: admin, override_reason: "CPA approved the transfer")
      end
    end
    expect(AuditLog.where(auditable: payout, action: "payout.backup_withholding_overridden").last.metadata)
      .to include("reason" => "CPA approved the transfer", "stage" => "transition")
  end
end
