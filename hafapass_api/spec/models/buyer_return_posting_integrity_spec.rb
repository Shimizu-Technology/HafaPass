# frozen_string_literal: true

require "rails_helper"

# Database guarantees for gross return postings and their recording times
# (docs/design/never-fulfilled-captures.md §5.2-§5.4, A1 tranche 3). Every
# bypass goes through raw SQL, update_all or validate: false: the triggers,
# not the writer, are the guarantee.
RSpec.describe "Buyer return posting integrity" do
  let(:connection) { ActiveRecord::Base.connection }

  def isolated(&block)
    ActiveRecord::Base.transaction(requires_new: true, &block)
  end

  def refund_on(payment, amount, status: :succeeded)
    payment.refunds.create!(order: payment.order, provider: "stripe", provider_refund_id: "re_int_#{SecureRandom.hex(4)}",
      idempotency_key: "int:#{SecureRandom.hex(6)}", amount_cents: amount, currency: "usd", status: status)
  end

  def dispute_on(payment, amount, status: :lost)
    Dispute.create!(order: payment.order, payment: payment, provider: "stripe", provider_dispute_id: "dp_int_#{SecureRandom.hex(4)}",
      amount_cents: amount, currency: "usd", status: status, opened_at: Time.current)
  end

  def raw_posting(capture, source, kind:, gross:, applied:, components:, sequence: nil, **extra)
    BuyerReturnPosting.new(unfulfilled_capture: capture, source: source, kind: kind, gross_cents: gross,
      applied_cents: applied, excess_cents: gross - applied, proceeds_cents: components[0], fee_cents: components[1],
      organizer_fee_cents: 0, tax_cents: 0, sequence: sequence || capture.buyer_return_postings.maximum(:sequence).to_i + 1,
      recording_source: "database", allocation_policy: capture.allocation_policy, policy_version: capture.policy_version,
      allocation_method: "bounded", recorded_at: nil, recognized_at: nil, capture_recorded_at: nil, **extra)
      .tap { |posting| posting.save!(validate: false) }
  end

  describe "recording times" do
    it "stamps a refund's success once, from the database clock, and never from the application" do
      _order, payment, = classified_capture(items: [[1200, 160, 0, 0]])
      pending = refund_on(payment, 100, status: :pending)
      expect(pending.reload.success_recorded_at).to be_nil
      pending.update!(status: :succeeded)
      stamped = pending.reload.success_recorded_at
      expect(stamped).to be_within(1.minute).of(Time.current)

      pending.update!(status: :failed)
      pending.update!(status: :succeeded)
      expect(pending.reload.success_recorded_at).to eq(stamped)
      expect { isolated { Refund.where(id: pending.id).update_all(success_recorded_at: 1.year.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect { isolated { Refund.where(id: pending.id).update_all(success_recorded_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)
      expect do
        isolated do
          payment.refunds.create!(order: payment.order, provider: "stripe", idempotency_key: "int:backdated",
            amount_cents: 1, currency: "usd", status: :succeeded, success_recorded_at: 1.month.ago)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /written by the database/)
    end

    it "stamps a dispute loss once and a loss reversal only on a recorded loss, then freezes both" do
      _order, payment, = classified_capture(items: [[1200, 160, 0, 0]])
      open = dispute_on(payment, 1360, status: :open)
      expect(open.reload.loss_recorded_at).to be_nil
      expect { isolated { Dispute.where(id: open.id).update_all(loss_reversed_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /Only a recorded dispute loss/)
      open.update!(status: :lost)
      expect(open.reload.loss_recorded_at).to be_within(1.minute).of(Time.current)
      expect { isolated { Dispute.where(id: open.id).update_all(loss_recorded_at: 1.year.ago) } }
        .to raise_error(ActiveRecord::StatementInvalid, /set once/)

      Dispute.where(id: open.id).update_all(loss_reversed_at: 10.years.ago)
      reversed = open.reload.loss_reversed_at
      expect(reversed).to be_within(1.minute).of(Time.current) # the database time, not the application's
      expect { isolated { Dispute.where(id: open.id).update_all(loss_reversed_at: nil) } }
        .to raise_error(ActiveRecord::StatementInvalid, /final/)
      expect { isolated { Dispute.where(id: open.id).update_all(status: Dispute.statuses[:won]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /final/)
      expect do
        isolated do
          Dispute.create!(order: payment.order, payment: payment, provider: "stripe", provider_dispute_id: "dp_int_reversed",
            amount_cents: 1, currency: "usd", status: :lost, opened_at: Time.current, loss_reversed_at: Time.current)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /reversed only after/)
    end
  end

  describe "postings" do
    it "accepts only a real movement of the classified payment, in sequence, with excess on gross and bounded shares" do
      order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
      _other_order, other_payment, = classified_capture(items: [[1200, 160, 0, 0]])
      refund = refund_on(payment, 500)

      expect { isolated { raw_posting(capture, refund_on(other_payment, 500), kind: "refund", gross: 500, applied: 500, components: [442, 58]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /must belong to the classified payment/)
      expect { isolated { raw_posting(capture, refund_on(payment, 5, status: :pending), kind: "refund", gross: 5, applied: 5, components: [5, 0]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /succeeded refund of the same gross/)
      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 400, applied: 400, components: [400, 0]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /same gross/)
      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 500, applied: 500, components: [442, 58], sequence: 2) } }
        .to raise_error(ActiveRecord::StatementInvalid, /sequenced/)
      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 500, applied: 499, components: [441, 58]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /smaller of its gross/)
      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 500, applied: 500, components: [300, 200]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /within the capture's components/)
      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 500, applied: 500, components: [442, 58], recognition_state: "closed") } }
        .to raise_error(ActiveRecord::StatementInvalid, /recognition_state_valid/)
      expect { isolated { raw_posting(capture, refund, kind: "refund_reversal", gross: -500, applied: -500, components: [-442, -58], reverses_posting_id: 0) } }
        .to raise_error(ActiveRecord::StatementInvalid, /approved finance correction|violates foreign key/)

      posting = raw_posting(capture, refund, kind: "refund", gross: 500, applied: 500, components: [442, 58])
      expect(posting.reload).to have_attributes(sequence: 1, recorded_at: refund.reload.success_recorded_at,
        capture_recorded_at: capture.capture_recorded_at,
        recognized_at: [refund.success_recorded_at, capture.capture_recorded_at].max)
      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 500, applied: 500, components: [442, 58]) } }
        .to raise_error(ActiveRecord::RecordNotUnique)

      # A second 1,360 loss: only 860 still owed, so 500 is excess on gross.
      loss = dispute_on(payment, 1360)
      expect { isolated { raw_posting(capture, loss, kind: "dispute_loss", gross: 1360, applied: 1360, components: [1200, 160]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /smaller of its gross/)
      raw_posting(capture, loss, kind: "dispute_loss", gross: 1360, applied: 860, components: [758, 102])
      expect(capture.buyer_return_postings.sum(:excess_cents)).to eq(500)
      expect(order.reload).to be_expired
    end

    it "requires a backfilled time with evidence, no later than the return cutover, for a movement recorded before A1" do
      _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
      refund = refund_on(payment, 100)
      stamp!(refund, :success_recorded_at, nil, trigger: "refunds_success_recorded_at")

      expect { isolated { raw_posting(capture, refund, kind: "refund", gross: 100, applied: 100, components: [88, 12]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /backfilled time/)
      connection.execute("INSERT INTO financial_cutovers (key) VALUES ('a1_return_recording') ON CONFLICT (key) DO NOTHING")
      expect do
        isolated do
          raw_posting(capture, refund, kind: "refund", gross: 100, applied: 100, components: [88, 12],
            recording_source: "backfill", recorded_at: 1.day.ago, evidence: {})
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /backfill/)
      expect do
        isolated do
          raw_posting(capture, refund, kind: "refund", gross: 100, applied: 100, components: [88, 12],
            recording_source: "backfill", recorded_at: 1.day.from_now, evidence: { "audit" => 1 })
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /no later than the cutover/)
      posting = raw_posting(capture, refund, kind: "refund", gross: 100, applied: 100, components: [88, 12],
        recording_source: "backfill", recorded_at: 2.days.ago, evidence: { "audit" => 1 })
      expect(posting.reload.recognized_at).to eq(capture.capture_recorded_at)
    end

    it "is append-only by every route" do
      _order, payment, capture = classified_capture(items: [[1200, 160, 0, 0]])
      posting = raw_posting(capture, refund_on(payment, 100), kind: "refund", gross: 100, applied: 100, components: [88, 12])

      expect(posting.reload).to be_readonly
      expect { isolated { BuyerReturnPosting.where(id: posting.id).update_all(gross_cents: 1) } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { isolated { BuyerReturnPosting.where(id: posting.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { isolated { connection.execute("TRUNCATE buyer_return_postings") } }
        .to raise_error(ActiveRecord::StatementInvalid, /cannot be truncated/)
    end
  end

  describe "schema reinstallation" do
    let(:triggers) do
      { "refunds" => %w[refunds_success_recorded_at], "disputes" => %w[disputes_recorded_at],
        "buyer_return_postings" => %w[buyer_return_postings_append_only buyer_return_postings_check
          buyer_return_postings_no_truncate] }
    end

    it "dumps the return triggers after the foundation and has them installed in this schema-loaded database" do
      output = StringIO.new
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, output)
      dump = output.string
      triggers.values.flatten.each { |name| expect(dump).to include("TRIGGER #{name}") }
      expect(dump.index("hafapass_check_buyer_return_posting")).to be > dump.index("hafapass_guard_ticket_issuance")

      installed = connection.select_rows(<<~SQL).group_by(&:first).transform_values { |rows| rows.map(&:last).sort }
        SELECT tgrelid::regclass::text, tgname FROM pg_trigger
        WHERE NOT tgisinternal AND tgrelid::regclass::text IN ('refunds', 'disputes', 'buyer_return_postings')
      SQL
      expect(installed).to eq(triggers.transform_values(&:sort))
    end
  end
end
