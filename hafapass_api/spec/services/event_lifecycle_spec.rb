require "rails_helper"

RSpec.describe EventLifecycle do
  let(:actor) { create(:user, :organizer) }
  let(:profile) { create(:organizer_profile, :verified, user: actor) }
  let(:event) { create(:event, organizer_profile: profile, starts_at: 5.days.from_now, max_capacity: 100) }

  before { create(:ticket_type, :free, event: event, quantity_available: 100) }

  it "publishes a ready event and writes an immutable transition record" do
    described_class.call(event: event, action: :publish, actor: actor)

    expect(event.reload).to be_published
    expect(event.event_state_changes.last).to have_attributes(
      action: "publish", from_status: "draft", to_status: "published", actor_user: actor
    )
    expect(event.event_state_changes.last.update(reason: "rewritten")).to be(false)
  end

  it "keeps lifecycle transitions available for events with legacy invalid page design" do
    event.update_columns(page_customization: { accent: "legacy-invalid" })
    event.reload

    described_class.call(event: event, action: :publish, actor: actor)
    described_class.call(event: event, action: :postpone, actor: actor, reason: "Venue closure")
    described_class.call(event: event, action: :cancel, actor: actor, reason: "Event cancelled")

    expect(event.reload).to be_cancelled
    expect(event.page_customization).to eq("accent" => "legacy-invalid")
  end

  it "rejects an incomplete event with its publishing checklist" do
    event.ticket_types.destroy_all

    expect {
      described_class.call(event: event, action: :publish, actor: actor)
    }.to raise_error(described_class::TransitionError) { |error|
      expect(error.checklist).to include(include(code: "tickets", complete: false))
    }
  end

  it "requires a declared venue capacity before publishing" do
    event.update!(max_capacity: nil)

    expect {
      described_class.call(event: event, action: :publish, actor: actor)
    }.to raise_error(described_class::TransitionError) { |error|
      expect(error.checklist).to include(
        include(code: "capacity", label: "Event capacity added and ticket inventory fits", complete: false)
      )
    }
  end

  it "publishes in production without any per-event launch-gate review" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)

    described_class.call(event: event, action: :publish, actor: actor)

    expect(event.reload).to be_published
  end

  it "requires a reason to postpone and stops sales after postponement" do
    described_class.call(event: event, action: :publish, actor: actor)

    expect {
      described_class.call(event: event, action: :postpone, actor: actor)
    }.to raise_error(described_class::TransitionError, /reason is required/)

    allow(EmailService).to receive(:send_event_change_notifications_async)
    described_class.call(event: event, action: :postpone, actor: actor, reason: "Venue closure")
    expect(event.reload).to be_postponed
    expect(event).not_to be_sales_open
    expect(event.event_state_changes.last.reason).to eq("Venue closure")
    expect(event.event_changes.last).to have_attributes(change_type: "postponed", reason: "Venue closure")
    expect(EmailService).to have_received(:send_event_change_notifications_async).with(event.event_changes.last)
  end

  it "does not complete an event before its end time" do
    described_class.call(event: event, action: :publish, actor: actor)

    expect {
      described_class.call(event: event, action: :complete, actor: actor)
    }.to raise_error(described_class::TransitionError, /before it ends/)
  end

  describe "archiving" do
    let(:ended) { create(:event, :completed, organizer_profile: profile) }

    def record_sale!(sale_event)
      order = create(:order, event: sale_event, subtotal_cents: 5000, service_fee_cents: 350, discount_cents: 0,
        total_cents: 5350, processing_fee_bearer_snapshot: "platform")
      item = create(:order_item, order: order, unit_price_cents: 5000, subtotal_cents: 5000, fee_cents: 350,
        organizer_proceeds_cents: 5000)
      create(:ticket, order: order, order_item: item, ticket_type: item.ticket_type, event: sale_event)
      component = create(:fee_component, order: order, order_item: item, kind: "processing", amount_cents: 185,
        estimated: false, provider_reference: "txn_fixture_#{SecureRandom.hex(8)}")
      capture = create(:payment, :succeeded, order: order, amount_cents: 5350)
      create(:stripe_fee_evidence, :verified, payment: capture, fee_component: component,
        provider_balance_transaction_id: component.provider_reference)
      order
    end

    def archive!(target = ended)
      described_class.call(event: target, action: :archive, actor: actor)
    end

    it "archives a draft without a statement" do
      archive!(event)

      expect(event.reload).to be_archived
    end

    it "refuses a completed or cancelled event until its statement is finalized" do
      cancelled = create(:event, :cancelled, organizer_profile: profile)

      [ended, cancelled].each do |target|
        expect { archive!(target) }.to raise_error(described_class::TransitionError, /Finalize this event's statement/)
        expect(target.reload.status).not_to eq("archived")
      end
    end

    it "refuses a stale statement and money still owed, then allows the final current version" do
      record_sale!(ended)
      first = Settlements::Finalizer.call(event: ended, actor: actor)
      expect { archive! }.to raise_error(described_class::TransitionError, /\$50\.00 is still payable/)

      record_sale!(ended)
      expect { archive! }.to raise_error(described_class::TransitionError, /changed after statement version #{first.version}/)

      second = Settlements::Finalizer.call(event: ended, actor: actor)
      payout = create(:payout, organization: ended.organization, event: ended, settlement: second,
        amount_cents: second.payable_cents, status: :processing)
      expect { archive! }.to raise_error(described_class::TransitionError, /changed after statement version/)
      Settlements::Finalizer.call(event: ended, actor: actor)
      expect { archive! }.to raise_error(described_class::TransitionError, /payout for this event is still in progress/)

      payout.update_columns(status: Payout.statuses[:paid], paid_at: Time.current, provider_payout_id: "po_fixture_final")
      expect { archive! }.to raise_error(described_class::TransitionError, /changed after statement version/)
      Settlements::Finalizer.call(event: ended, actor: actor)
      archive!

      expect(ended.reload).to be_archived
      expect(AuditLog.where(action: "event.archived", auditable: ended).count).to eq(1)
    end

    it "refuses while a refund is pending or a dispute is open, even with a current paid statement" do
      Settlements::Finalizer.call(event: ended, actor: actor)
      order = create(:order, event: ended)
      refund = create(:refund, order: order, status: :pending, succeeded_at: nil)

      expect { archive! }.to raise_error(described_class::TransitionError, /Resolve pending refunds and open disputes before archiving/)
      expect(ended.reload).to be_completed

      refund.update_columns(status: Refund.statuses[:failed])
      Dispute.create!(order: order, provider: "stripe", provider_dispute_id: "dp_archive", amount_cents: 100,
        currency: "usd", opened_at: Time.current)
      expect { archive! }.to raise_error(described_class::TransitionError, /Resolve pending refunds and open disputes before archiving/)
      expect(ended.reload).to be_completed
    end

    it "refuses while a reconciliation exception on its orders is open" do
      Settlements::Finalizer.call(event: ended, actor: actor)
      create(:reconciliation_exception, order: create(:order, event: ended), code: "payment_amount_mismatch")

      expect { archive! }.to raise_error(described_class::TransitionError, /Resolve open reconciliation exceptions before archiving/)
    end

    it "lets an administrator restore an archived event to its previous status with a reason" do
      Settlements::Finalizer.call(event: ended, actor: actor)
      archive!
      admin = create(:user, :admin)

      expect {
        described_class.call(event: ended, action: :unarchive, actor: admin)
      }.to raise_error(described_class::TransitionError, /reason is required/)
      described_class.call(event: ended, action: :unarchive, actor: admin, reason: "Statement needs another version")

      expect(ended.reload).to be_completed
      expect(ended.event_state_changes.order(:id).last).to have_attributes(action: "unarchive", from_status: "archived",
        to_status: "completed", actor_user: admin, reason: "Statement needs another version")
      expect(AuditLog.find_by!(action: "event.unarchived", auditable: ended)).to have_attributes(actor_user_id: admin.id)
      expect { described_class.call(event: ended, action: :unarchive, actor: admin, reason: "again") }
        .to raise_error(described_class::TransitionError, /Cannot unarchive/)
    end
  end
end
