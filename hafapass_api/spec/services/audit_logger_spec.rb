# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditLogger do
  let(:event) { create(:event) }
  let(:actor) { event.organizer_profile.user }

  it "resolves tenant and event through ticket, order, support note and delivery subjects" do
    order = create(:order, event: event)
    ticket = create(:ticket, event: event, order: order)
    note = SupportNote.create!(author_user: actor, ticket: ticket, body: "Checked the order")
    delivery = create(:message_delivery, order: order, event: nil)
    [order, ticket, note, delivery].each do |subject|
      log = described_class.record!(action: "support.note_created", auditable: subject, actor: actor)
      expect(log).to have_attributes(organization_id: event.organization_id, event_id: event.id,
        actor_user_id: actor.id, outcome: "succeeded", source: "user")
    end
  end

  it "rejects missing tenant context and mismatched events" do
    expect { described_class.record!(action: "organization.updated", auditable: create(:user)) }
      .to raise_error(ArgumentError, /Organization is required/)
    other = create(:event)
    expect { described_class.record!(action: "event.updated", auditable: event, organization: other.organization) }
      .to raise_error(ArgumentError, /does not match|does not belong/)
    expect { described_class.record!(action: "event.updated", auditable: event, event: other) }
      .to raise_error(ArgumentError)
  end

  it "deduplicates provider retry keys without swallowing audit validation errors" do
    args = { action: "event.updated", auditable: event, source: "provider", deduplication_key: "provider/event-1" }
    first = described_class.record!(**args)
    expect { expect(described_class.record!(**args).id).to eq(first.id) }.not_to change(AuditLog, :count)
    expect { described_class.record!(**args.merge(outcome: "invented"), deduplication_key: "provider/event-2") }
      .to raise_error(AuditLogger::WriteError)
    expect { described_class.record!(**args.merge(auditable: create(:event))) }.to raise_error(ArgumentError)
  end

  it "rolls back an audit when its surrounding mutation rolls back" do
    event
    expect do
      Event.transaction do
        described_class.record!(action: "event.updated", auditable: event)
        raise ActiveRecord::Rollback
      end
    end.not_to change(AuditLog, :count)
  end

  it "rolls back team role changes when the audit insert fails" do
    membership = create(:organization_membership, organization: event.organization, role: :finance)
    allow(AuditLog).to receive(:create!).and_raise("audit unavailable")
    expect { OrganizationTeam.change_role!(membership: membership, role: :manager, actor: actor) }
      .to raise_error("audit unavailable")
    expect(membership.reload).to be_finance
  end

  it "keeps unknown action keys administrator-only" do
    expect(AuditActions.fetch("unknown.future_action")[:audience]).to include("admin_only")
  end
end
