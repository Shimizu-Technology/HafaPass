# frozen_string_literal: true

require "rails_helper"

RSpec.describe AuditLog do
  let(:entry) { AuditLogger.record!(action: "organization.updated", auditable: create(:organization), metadata: { value: "personal" }) }

  def isolated_statement(&block)
    described_class.transaction(requires_new: true, &block)
  end

  it "blocks raw SQL payload changes and deletes" do
    row = entry
    expect { isolated_statement { described_class.where(id: row.id).update_all(metadata: {}) } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { isolated_statement { described_class.where(id: row.id).delete_all } }
      .to raise_error(ActiveRecord::StatementInvalid, /cannot be deleted/)
  end

  it "allows controlled redaction, preserves identity, and restores the setting" do
    row = entry
    original = row.attributes.except(*described_class::REDACTABLE_COLUMNS)
    described_class.redact!(described_class.where(id: row.id), { metadata: {}, ip_address: nil, retention_anonymized_at: Time.current })
    expect(row.reload.metadata).to eq({})
    expect(row.attributes.except(*described_class::REDACTABLE_COLUMNS)).to eq(original)
    expect(described_class.connection.select_value("SELECT current_setting('hafapass.audit_redaction', true)")).not_to eq("on")
    expect { described_class.redact!(described_class.where(id: row.id), { action: "spoofed" }) }
      .to raise_error(ArgumentError)
  end

  it "blocks identity changes even when the redaction setting is enabled" do
    row = entry
    expect do
      isolated_statement do
        described_class.connection.execute("SELECT set_config('hafapass.audit_redaction', 'on', true)")
        described_class.where(id: row.id).update_all(action: "spoofed")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /identity cannot be redacted/)
  end

  it "allows a hard-deleted actor and subject to retain their historical ids" do
    actor = create(:user)
    row = AuditLogger.record!(action: "user.role_changed", auditable: actor, actor: actor)
    actor_id = actor.id
    actor.destroy!
    expect(row.reload).to have_attributes(actor_user_id: actor_id, auditable_id: actor_id, auditable_type: "User")
    expect(row.actor_user).to be_nil
  end

  it "preserves event identity through the draft event deletion path" do
    event = create(:event)
    row = AuditLogger.record!(action: "event.updated", auditable: event, event: event)
    event_id = event.id
    event.destroy!
    expect(row.reload).to have_attributes(event_id: event_id, auditable_id: event_id)
    expect(row.event).to be_nil
  end

  it "blocks deleting an audited organization with a clear model error and a restrictive FK" do
    organization = Organization.create!(name: "Historical organizer", timezone: "Pacific/Guam", currency: "USD")
    AuditLogger.record!(action: "organization.updated", auditable: organization)
    expect(organization.destroy).to be(false)
    expect(organization.errors.full_messages.join).to match(/audit logs/i)
    expect { isolated_statement { Organization.where(id: organization.id).delete_all } }
      .to raise_error(ActiveRecord::InvalidForeignKey)
    fks = described_class.connection.foreign_keys(:audit_logs)
    expect(fks.map(&:column)).to eq(["organization_id"])
    expect(fks.sole.on_delete).to eq(:restrict)
    incoming = described_class.connection.select_values("SELECT conname FROM pg_constraint WHERE contype = 'f' AND confrelid = 'audit_logs'::regclass")
    expect(incoming).to be_empty
  end

  it "includes the trigger in schema dumps for fresh databases" do
    output = StringIO.new
    ActiveRecord::SchemaDumper.dump(described_class.connection_pool, output)
    expect(output.string).to include("CREATE TRIGGER audit_logs_append_only", "hafapass_protect_audit_log")
  end
end
