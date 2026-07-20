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
