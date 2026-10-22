# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Tax operations services" do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let!(:tax) { create(:organizer_tax_information, organization: organization) }

  describe TinMatching do
    it "exports the IRS four-field format and imports all nine result codes without auditing a full TIN" do
      line = described_class.export!(actor: admin).strip
      fields = line.split(";")
      expect(fields.length).to eq(4)
      expect(fields[0]).to eq("1")
      expect(fields[1]).to eq(tax.tin)
      expect(fields[3]).to match(/\A[0-9a-f]{20}\z/)

      (0..8).each do |code|
        tax.update!(tin_match_status: "unverified")
        line = described_class.export!(actor: admin).strip
        result = described_class.import!(content: "#{line.strip};#{code}\n", actor: admin)
        expect(result).to eq(OrganizerTaxInformation::MATCH_RESULTS.fetch(code) => 1)
        expect(tax.reload.tin_match_result_code).to eq(code)
      end
      expect(AuditLog.where(action: "tin_matching.imported").count).to eq(9)
      expect(AuditLog.where(action: ["tin_matching.imported", "tin_matching.exported"]).map(&:metadata).to_json).not_to include(tax.tin)
    end

    it "rejects stale, unknown, duplicate, and altered result rows atomically" do
      line = described_class.export!(actor: admin).strip
      expect { described_class.import!(content: "#{line};0\n#{line};3\n", actor: admin) }
        .to raise_error(TinMatching::ImportError, /repeated account/)
      expect(tax.reload.tin_match_status).to eq("unverified")
      expect { described_class.import!(content: "#{line.sub(tax.tin, '999999999')};0\n", actor: admin) }
        .to raise_error(TinMatching::ImportError, /does not match/)
      tax.update!(tin: "987654321")
      expect { described_class.import!(content: "#{line};0\n", actor: admin) }
        .to raise_error(TinMatching::ImportError, /does not match/)
      expect(AuditLog.where(action: "tin_matching.imported")).to be_empty
    end
  end

  describe BackupWithholding do
    it "blocks by default, withholds exactly to the cent when enabled, and audits an admin override" do
      tax.update!(backup_withholding_flag: true, backup_withholding_reason: "CPA withholding review")
      expect { described_class.for_payout(organization: organization, amount_cents: 10_003, actor: admin) }
        .to raise_error(BackupWithholding::WithholdingError, /blocks/)
      SiteSetting.instance.update!(backup_withholding_mode: "withhold")
      decision = described_class.for_payout(organization: organization, amount_cents: 10_003, actor: admin)
      expect(decision).to include(withheld_cents: 2401, withholding_rate_bps: 2400)
      expect(10_003 - decision[:withheld_cents]).to eq(7602)
      expect(SiteSetting.instance.update(backup_withholding_rate_bps: 0)).to be(false)
      SiteSetting.instance.reload
      expect { described_class.for_payout(organization: organization, amount_cents: 100, actor: admin,
        override_reason: "TIN 012345678 should pass") }.to raise_error(BackupWithholding::WithholdingError, /without a TIN/)
      expect { described_class.for_payout(organization: organization, amount_cents: 100, actor: admin,
        override_reason: "TIN 012.34.5678 should pass") }.to raise_error(BackupWithholding::WithholdingError, /without a TIN/)
      SiteSetting.instance.update!(backup_withholding_mode: "block")
      expect(described_class.for_payout(organization: organization, amount_cents: 10_003, actor: admin,
        override_reason: "CPA authorized payout after review")[:withheld_cents]).to eq(0)
    end

    it "activates an unresolved mismatch after the notice window and clears it on a new W-9" do
      tax.update!(tin_match_status: "mismatch", b_notice_stage: "first",
        b_notice_sent_at: 45.days.ago, b_notice_response_due_on: Date.yesterday)
      expect(tax.backup_withholding_required?).to be(true)
      expect(BNotice.business_days_after(Date.new(2026, 12, 24), 1)).to eq(Date.new(2026, 12, 28))
    end
  end

  describe AnnualPayeeReport do
    it "reports gross, withheld, and net in cents while keeping the PDF masked" do
      event = create(:event, organization: organization)
      create(:payout, organization: organization, event: event,
        settlement: create(:settlement, organization: organization, event: event),
        connected_account: create(:connected_account, organization: organization),
        status: :paid, amount_cents: 10_003, withheld_cents: 2401,
        paid_at: Time.utc(2026, 10, 4))
      order = create(:order, event: event)
      item = create(:order_item, order: order)
      refund = create(:refund, order: order, amount_cents: 500, succeeded_at: Time.utc(2026, 10, 5))
      create(:refund_item, refund: refund, order_item: item, amount_cents: 500,
        organizer_proceeds_cents: 450, fee_cents: 50)
      report = described_class.new(organization: organization, year: 2026)
      expect(report.row).to include(gross_paid_cents: 10_003, withheld_cents: 2401,
        net_disbursed_cents: 7602, refund_clawbacks_cents: 450, form_type: "review_required",
        jurisdiction: "irs", reporting_status: "cpa_review")
      expect(report.statement_pdf).not_to include(tax.tin)
      AnnualTaxReportSetting.create!(organization: organization, year: 2026, form_type: "1099-misc", jurisdiction: "guam_drt")
      expect(report.row).to include(threshold_cents: 200_000, threshold_met: false, jurisdiction: "guam_drt")
    end

    it "separates historical payout identities after an organizer changes W-9 details" do
      event = create(:event, organization: organization)
      settlement = create(:settlement, organization: organization, event: event)
      account = create(:connected_account, organization: organization)
      first = create(:payout, organization: organization, event: event,
        settlement: settlement, connected_account: account, status: :paid,
        amount_cents: 5000, paid_at: Time.utc(2026, 10, 4))
      tax.update!(legal_name: "New Legal Payee", tin: "987654321")
      second = create(:payout, organization: organization, event: event,
        settlement: settlement, connected_account: account, status: :paid,
        amount_cents: 7500, paid_at: Time.utc(2026, 10, 5))
      reports = described_class.for_organization(organization: organization, year: 2026)
      expect(reports.length).to eq(2)
      expect(reports.map { |report| [report.row[:legal_name], report.row[:gross_paid_cents], report.payee_tin] })
        .to contain_exactly(["Island Events LLC", 5000, "012345678"], ["New Legal Payee", 7500, "987654321"])
      expect(described_class.payee_key_for(first)).not_to eq(described_class.payee_key_for(second))
      expect(reports.map(&:row).to_json).not_to include("012345678", "987654321")
    end

    it "uses the payout payee snapshot when a W-9 was missing" do
      event = create(:event, organization: organization)
      payout = create(:payout, organization: organization, event: event,
        settlement: create(:settlement, organization: organization, event: event),
        connected_account: create(:connected_account, organization: organization),
        status: :paid, amount_cents: 5000, withheld_cents: 1200, paid_at: Time.utc(2026, 10, 4),
        with_tax_snapshot: false, tax_information_snapshot: {}, tax_information_tin: nil,
        payee_snapshot: { "payee_name" => "Island Events Check" })

      report = described_class.new(organization: organization, year: 2026,
        payee_key: described_class.payee_key_for(payout))
      expect(report.row).to include(legal_name: "Island Events Check", gross_paid_cents: 5000,
        withheld_cents: 1200, net_disbursed_cents: 3800)
    end
  end
end
