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

  it "blocks production publication without a current event-specific readiness approval" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)

    expect {
      described_class.call(event: event, action: :publish, actor: actor)
    }.to raise_error(described_class::TransitionError) { |error|
      expect(error.checklist).to include(
        include(code: "pilot_readiness_approved", complete: false)
      )
    }
  end

  it "blocks production publication after Gate E until candidate validation is approved" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)
    readiness = instance_double(PilotReadinessReview)
    expect(PilotReadiness).to receive(:event_state_digest).with(event).once.and_return("a" * 64)
    allow(PilotReadiness).to receive(:active_approval)
      .with(event, at: anything, state_digest: "a" * 64).and_return(readiness)
    allow(PilotValidation).to receive(:active_approval)
      .with(event, at: anything, readiness_approval: readiness, state_digest: "a" * 64).and_return(nil)

    expect do
      described_class.call(event: event, action: :publish, actor: actor)
    end.to raise_error(described_class::TransitionError) { |error|
      expect(error.checklist).to include(include(code: "pilot_validation_approved", complete: false))
    }
  end

  it "blocks production publication after Gate F until the physical event-day rehearsal is approved" do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(PolicyRegistry).to receive(:production_approved?).and_return(true)
    readiness = instance_double(PilotReadinessReview)
    validation = instance_double(PilotValidationReview)
    expect(PilotReadiness).to receive(:event_state_digest).with(event).once.and_return("a" * 64)
    allow(PilotReadiness).to receive(:active_approval)
      .with(event, at: anything, state_digest: "a" * 64).and_return(readiness)
    allow(PilotValidation).to receive(:active_approval)
      .with(event, at: anything, readiness_approval: readiness, state_digest: "a" * 64).and_return(validation)
    allow(EventDayRehearsal).to receive(:active_approval)
      .with(event, at: anything, validation_approval: validation, state_digest: "a" * 64).and_return(nil)

    expect do
      described_class.call(event: event, action: :publish, actor: actor)
    end.to raise_error(described_class::TransitionError) { |error|
      expect(error.checklist).to include(include(code: "event_day_rehearsal_approved", complete: false))
    }
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
end
