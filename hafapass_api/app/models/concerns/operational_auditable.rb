# frozen_string_literal: true

# Audit writes deliberately run inside the mutation transaction. Only explicitly
# selected scalar fields may enter snapshots; text/contact/credential fields can
# be observed by name without retaining their values.
module OperationalAuditable
  extend ActiveSupport::Concern

  included do
    class_attribute :operational_audit_prefix, :operational_audit_fields, :operational_audit_observed_fields,
      instance_writer: false

    after_create { audit_operational_mutation!(:create) }
    after_update { audit_operational_mutation!(:update) }
    after_destroy { audit_operational_mutation!(:destroy) }
  end

  class_methods do
    def audits_operations(prefix, fields:, observe: [])
      self.operational_audit_prefix = prefix.to_s
      self.operational_audit_fields = fields.map(&:to_s).freeze
      self.operational_audit_observed_fields = observe.map(&:to_s).freeze
    end
  end

  private

  def audit_operational_mutation!(operation)
    fields = operational_audit_fields + operational_audit_observed_fields
    changed = operation == :destroy ? fields : saved_changes.keys & fields
    return if operation == :update && changed.empty?

    action = operational_audit_action(operation)
    return unless action

    selected = operational_audit_fields & changed
    before_data = case operation
    when :create then {}
    when :update then selected.to_h { |field| [field, saved_change_to_attribute(field).first] }
    when :destroy then attributes.slice(*selected)
    end
    after_data = operation == :destroy ? {} : attributes.slice(*selected)
    record_operational_audit!(action: action, before_data: before_data, after_data: after_data,
      metadata: { changed_fields: changed }.merge(operational_audit_metadata(operation)),
      actor: operational_audit_actor(operation))
  end

  def operational_audit_action(operation)
    suffix = { create: "created", update: "updated", destroy: "deleted" }.fetch(operation)
    "#{operational_audit_prefix}.#{suffix}"
  end

  def operational_audit_actor(_operation)
    AuditContext.current.actor
  end

  def operational_audit_metadata(_operation)
    {}
  end

  def operational_audit_event
    return self if is_a?(Event)
    return event if respond_to?(:event)

    nil
  end

  def record_operational_audit!(action:, before_data: {}, after_data: {}, metadata: {}, actor: AuditContext.current.actor,
    deduplication_key: nil)
    AuditLogger.record!(action: action, auditable: self, event: operational_audit_event,
      actor: actor, source: actor ? (AuditContext.current.source.presence || "user") : "system",
      outcome: operational_audit_outcome(action), before_data: before_data, after_data: after_data, metadata: metadata,
      deduplication_key: deduplication_key)
  end

  def operational_audit_outcome(_action)
    "succeeded"
  end
end
