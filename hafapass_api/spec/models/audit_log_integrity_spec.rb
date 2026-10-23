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

  it "includes the trigger in schema dumps for fresh databases" do
    output = StringIO.new
    ActiveRecord::SchemaDumper.dump(described_class.connection_pool, output)
    expect(output.string).to include("CREATE TRIGGER audit_logs_append_only", "hafapass_protect_audit_log")
  end
end
