# frozen_string_literal: true

# The initiator follows queued work; a worker must not substitute the record's
# creator for the person who actually requested an operation.
class AuditContext < ActiveSupport::CurrentAttributes
  attribute :actor, :request_id, :ip_address, :source, :job_id

  def self.current
    instance
  end

  def self.snapshot
    { "actor_id" => actor&.id, "request_id" => request_id,
      "ip_address" => ip_address, "source" => source }
  end

  def self.restore(data, job_id: nil, &block)
    data ||= {}
    set(actor: User.find_by(id: data["actor_id"]), request_id: data["request_id"],
      ip_address: data["ip_address"], source: data["source"] || "system", job_id: job_id, &block)
  end
end
