# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Tax operations services" do
  let(:admin) { create(:user, :admin) }
  let(:organization) { create(:organization) }
  let!(:tax) { create(:organizer_tax_information, organization: organization) }

  describe TinMatching do
    it "exports the IRS four-field format and imports all nine result codes without auditing a full TIN" do
      line = described_class.export!(actor: admin, purpose: "IRS matching review").strip
      fields = line.split(";")
      expect(fields.length).to eq(4)
      expect(fields[0]).to eq("1")
      expect(fields[1]).to eq(tax.tin)
      expect(fields[3]).to match(/\A[0-9a-f]{20}\z/)

      (0..8).each do |code|
        tax.update!(tin_match_status: "unverified")
        line = described_class.export!(actor: admin, purpose: "IRS matching review").strip
        result = described_class.import!(content: "#{line.strip};#{code}\n", actor: admin)
        expect(result).to eq(OrganizerTaxInformation::MATCH_RESULTS.fetch(code) => 1)
        expect(tax.reload.tin_match_result_code).to eq(code)
      end
      expect(AuditLog.where(action: "tin_matching.imported").count).to eq(9)
      expect(AuditLog.where(action: ["tin_matching.imported", "tin_matching.exported"]).map(&:metadata).to_json).not_to include(tax.tin)
    end

    it "rejects stale, unknown, duplicate, and altered result rows atomically" do
      line = described_class.export!(actor: admin, purpose: "IRS matching review").strip
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

  describe "second B-notice validation" do
    it "does not clear withholding when a later TIN match says matched" do
      tax.update!(tin_match_status: "unverified", b_notice_stage: "second",
        b_notice_response_due_on: Date.yesterday)
      request_line = TinMatching.export!(actor: admin, purpose: "IRS matching review").strip
      TinMatching.import!(content: "#{request_line};0\n", actor: admin)
      expect(tax.reload.tin_match_status).to eq("mismatch")
      expect(tax.backup_withholding_required?).to be(true)
      tax.update!(tin_match_status: "matched")
      expect(tax.reload.backup_withholding_required?).to be(true)
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
        override_reason: "TIN 012345678 should pass") }.to raise_error(BackupWithholding::WithholdingError, /This looks like a taxpayer ID/)
      expect { described_class.for_payout(organization: organization, amount_cents: 100, actor: admin,
        override_reason: "TIN 012.34.5678 should pass") }.to raise_error(BackupWithholding::WithholdingError, /This looks like a taxpayer ID/)
      SiteSetting.instance.update!(backup_withholding_mode: "block")
      expect(described_class.for_payout(organization: organization, amount_cents: 10_003, actor: admin,
        override_reason: "CPA authorized payout after review")[:withheld_cents]).to eq(0)
    end

    it "activates an unresolved mismatch after the notice window and excludes federal holidays" do
      tax.update!(tin_match_status: "mismatch", b_notice_stage: "first",
        b_notice_sent_at: 45.days.ago, b_notice_response_due_on: Date.yesterday)
      expect(tax.backup_withholding_required?).to be(true)
      expect(BNotice.business_days_after(Date.new(2026, 12, 24), 1)).to eq(Date.new(2026, 12, 28))
      expect(BNotice.business_days_after(Date.new(2026, 6, 18), 1)).to eq(Date.new(2026, 6, 22))
      tax.update!(irs_notice_received_on: 15.days.ago.to_date,
        b_notice_send_due_on: BNotice.business_days_after(Date.current, 2), b_notice_sent_at: nil)
      expect(tax.safe_json["b_notice_send_at_risk"]).to be(true)
    end
  end

  describe OrganizerTaxInformationUpdater do
    it "preserves second-notice withholding until an admin records IRS validation" do
      tax.update!(tin_match_status: "mismatch", b_notice_stage: "second",
        first_b_notice_received_on: 1.year.ago.to_date, irs_notice_received_on: 40.days.ago.to_date,
        b_notice_response_due_on: Date.yesterday)
      described_class.call(organization: organization, actor: admin,
        attributes: { certified: true, legal_name: tax.legal_name, tin_type: tax.tin_type,
          tin: tax.tin, tax_classification: tax.tax_classification,
          mailing_address: tax.mailing_address, signer_name: tax.signer_name })
      expect(tax.reload).to have_attributes(b_notice_stage: "second", tin_match_status: "mismatch")
      expect(tax.backup_withholding_required?).to be(true)
    end

    it "withholds for an unverified replacement TIN after a second notice, even before the old deadline" do
      tax.update!(tin_match_status: "mismatch", b_notice_stage: "second",
        b_notice_response_due_on: Date.tomorrow)
      described_class.call(organization: organization, actor: admin,
        attributes: { certified: true, legal_name: tax.legal_name, tin_type: tax.tin_type,
          tin: "987654321", tax_classification: tax.tax_classification,
          mailing_address: tax.mailing_address, signer_name: tax.signer_name })
      expect(tax.reload.tin_match_status).to eq("unverified")
      expect(tax.second_notice_identity_changed?).to be(true)
      expect(tax.backup_withholding_required?).to be(true)

      line = TinMatching.export!(actor: admin, purpose: "IRS matching review").strip
      TinMatching.import!(content: "#{line};0\n", actor: admin)
      expect(tax.reload.tin_match_current?).to be(true)
      expect(tax.backup_withholding_required?).to be(false)
    end

    it "clears a first notice while retaining its stage and receipt history" do
      tax.update!(tin_match_status: "mismatch", b_notice_stage: "first",
        first_b_notice_received_on: Date.current, irs_notice_received_on: Date.current)
      described_class.call(organization: organization, actor: admin,
        attributes: { certified: true, legal_name: tax.legal_name, tin_type: tax.tin_type,
          tin: tax.tin, tax_classification: tax.tax_classification,
          mailing_address: tax.mailing_address, signer_name: tax.signer_name })
      expect(tax.reload).to have_attributes(b_notice_stage: "first", tin_match_status: "unverified",
        first_b_notice_received_on: Date.current)
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

    it "keeps a 2027 refund row for the 2026 payee and follows sale lines when the event payee changes" do
      event = create(:event, organization: organization)
      account = create(:connected_account, organization: organization)
      order = create(:order, event: event)
      item = create(:order_item, order: order)
      first_settlement = create(:settlement, organization: organization, event: event)
      first_settlement.settlement_items.create!(kind: "sale_proceeds", amount_cents: 500,
        currency: organization.currency, description: "Sale", occurred_at: Time.utc(2026, 9, 1),
        source_type: "OrderItem", source_id: item.id)
      first = create(:payout, organization: organization, event: event, settlement: first_settlement,
        connected_account: account, status: :paid, paid_at: Time.utc(2026, 10, 1))
      tax.update!(legal_name: "New Event Payee", tin: "987654321")
      second = create(:payout, organization: organization, event: event,
        settlement: create(:settlement, organization: organization, event: event),
        connected_account: account, status: :paid, paid_at: Time.utc(2026, 12, 1))
      refund = create(:refund, order: order, amount_cents: 500, succeeded_at: Time.utc(2027, 1, 2))
      create(:refund_item, refund: refund, order_item: item, amount_cents: 500, organizer_proceeds_cents: 450, fee_cents: 50)
      reports = described_class.for_organization(organization: organization, year: 2027)
      expect(reports.length).to eq(1)
      expect(reports.first.payee_key).to eq(described_class.payee_key_for(first))
      expect(reports.first.payee_key).not_to eq(described_class.payee_key_for(second))
      expect(reports.first.row).to include(gross_paid_cents: 0, refund_clawbacks_cents: 450)
    end

    it "allocates a refund across both paid identities by line proceeds, including largest-remainder cents" do
      event = create(:event, organization: organization)
      account = create(:connected_account, organization: organization)
      order = create(:order, event: event)
      item = create(:order_item, order: order)
      paid_at = Time.utc(2026, 10, 1)
      first_settlement = create(:settlement, organization: organization, event: event)
      first_settlement.settlement_items.create!(kind: "sale_proceeds", amount_cents: 100,
        currency: organization.currency, description: "Partial sale", occurred_at: paid_at,
        source_type: "OrderItem", source_id: item.id)
      first = create(:payout, organization: organization, event: event, settlement: first_settlement,
        connected_account: account, status: :paid, amount_cents: 100, paid_at: paid_at)
      tax.update!(legal_name: "New Legal Payee", tin: "987654321")
      second_settlement = create(:settlement, organization: organization, event: event)
      second_settlement.settlement_items.create!(kind: "sale_proceeds", amount_cents: 400,
        currency: organization.currency, description: "Remaining sale", occurred_at: paid_at + 1.day,
        source_type: "OrderItem", source_id: item.id)
      second = create(:payout, organization: organization, event: event, settlement: second_settlement,
        connected_account: account, status: :paid, amount_cents: 400, paid_at: paid_at + 1.day)
      refund = create(:refund, order: order, amount_cents: 450, succeeded_at: Time.utc(2027, 1, 2))
      create(:refund_item, refund: refund, order_item: item, amount_cents: 450,
        organizer_proceeds_cents: 450, fee_cents: 0)
      rows = described_class.for_organization(organization: organization, year: 2027).to_h do |report|
        [report.payee_key, report.row[:refund_clawbacks_cents]]
      end
      expect(rows).to eq(described_class.payee_key_for(first) => 90, described_class.payee_key_for(second) => 360)

      rounding_refund = create(:refund, order: order, amount_cents: 451, succeeded_at: Time.utc(2027, 1, 3))
      create(:refund_item, refund: rounding_refund, order_item: item, amount_cents: 451,
        organizer_proceeds_cents: 451, fee_cents: 0)
      rounded = described_class.for_organization(organization: organization, year: 2027).to_h do |report|
        [report.payee_key, report.row[:refund_clawbacks_cents]]
      end
      expect(rounded).to eq(described_class.payee_key_for(first) => 180, described_class.payee_key_for(second) => 721)
      expect(rounded.values.sum).to eq(901)
    end

    it "reads per-form per-year threshold settings" do
      setting = AnnualTaxThreshold.for(year: 2026, form_type: "1099-nec")
      setting.save!
      setting.update!(amount_cents: 250_000)
      expect(setting.amount_cents).to eq(250_000)
      expect(AnnualTaxThreshold.for(year: 2025, form_type: "1099-nec").amount_cents).to eq(60_000)
      expect(AnnualTaxThreshold.for(year: 2026, form_type: "1099-k").transaction_count).to eq(200)
      AnnualTaxReportSetting.create!(organization: organization, year: 2026, form_type: "1099-k")
      expect(described_class.new(organization: organization, year: 2026).row[:threshold_met]).to be_nil
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
