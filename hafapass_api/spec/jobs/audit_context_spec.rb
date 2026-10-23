# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Audit context in jobs" do
  it "serializes the initiator and request context and restores them only during execution" do
    actor = create(:user)
    request_id = "audit-request-123"
    serialized = AuditContext.set(actor: actor, request_id: request_id, ip_address: "127.0.0.1", source: "user") do
      ApplicationJob.new.serialize
    end
    job = ApplicationJob.deserialize(serialized)
    expect(job.audit_context).to include("actor_id" => actor.id, "request_id" => request_id)
    expect(AuditContext.actor).to be_nil
    AuditContext.restore(job.audit_context, job_id: job.job_id) do
      expect(AuditContext.actor).to eq(actor)
      expect(AuditContext.request_id).to eq(request_id)
      expect(AuditContext.source).to eq("user")
      expect(AuditContext.job_id).to eq(job.job_id)
    end
    expect(AuditContext.actor).to be_nil
    expect(AuditContext.request_id).to be_nil
  end

  it "does not invent an actor for old queued jobs without context" do
    AuditContext.restore(nil) do
      expect(AuditContext.actor).to be_nil
      expect(AuditContext.source).to eq("system")
    end
  end
end
