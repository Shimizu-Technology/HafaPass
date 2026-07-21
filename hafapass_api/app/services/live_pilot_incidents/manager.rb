# frozen_string_literal: true

module LivePilotIncidents
  class Manager
    class IncidentError < StandardError; end

    def self.report!(run:, actor:, attributes:, request: nil)
      validate_admin!(actor)
      incident = nil
      run.event.with_lock do
        run.lock!
        raise IncidentError, "Incidents can only be reported against an open pilot run" unless
          run.status_active? || run.status_paused?
        incident = run.live_pilot_incidents.create!(
          event: run.event, actor_user: actor, action: :report,
          severity: attributes[:severity], category: attributes[:category],
          summary: attributes[:summary].to_s.strip,
          evidence_reference: attributes[:evidence_reference].to_s.strip,
          evidence_digest: attributes[:evidence_digest].to_s.strip,
          occurred_at: operation_time(attributes[:occurred_at], run: run)
        )
        record!(incident, "live_pilot_incident.reported", actor, request)
        if incident.pause_required? && run.status_active?
          LivePilotRuns::Manager.pause!(
            run: run, actor: actor, reason: "#{incident.severity.upcase} #{incident.category}: #{incident.summary}",
            request: request
          )
        end
      end
      incident
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise IncidentError, error_message(e)
    rescue LivePilotRuns::Manager::RunError => e
      raise IncidentError, e.message
    end

    def self.resolve!(incident:, actor:, attributes:, request: nil)
      validate_admin!(actor)
      resolution = nil
      incident.event.with_lock do
        incident.lock!
        raise IncidentError, "Only an incident report can be resolved" unless incident.action_report?
        raise IncidentError, "This incident is already resolved" if incident.resolution
        resolution = incident.live_pilot_run.live_pilot_incidents.create!(
          event: incident.event, parent_incident: incident, actor_user: actor, action: :resolution,
          severity: incident.severity, category: incident.category,
          summary: attributes[:summary].to_s.strip,
          evidence_reference: attributes[:evidence_reference].to_s.strip,
          evidence_digest: attributes[:evidence_digest].to_s.strip,
          occurred_at: operation_time(attributes[:occurred_at], run: incident.live_pilot_run)
        )
        record!(resolution, "live_pilot_incident.resolved", actor, request)
      end
      resolution
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise IncidentError, error_message(e)
    end

    def self.operation_time(value, run:)
      parsed = value.blank? ? Time.current : Time.iso8601(value.to_s)
      raise IncidentError, "Incident time cannot predate the pilot run" if parsed < run.started_at
      raise IncidentError, "Incident time cannot be in the future" if parsed > Time.current

      parsed
    rescue ArgumentError
      raise IncidentError, "Incident time must be an ISO-8601 timestamp"
    end
    private_class_method :operation_time

    def self.validate_admin!(actor)
      raise IncidentError, "Only an administrator can manage Gate I incidents" unless actor&.admin?
    end
    private_class_method :validate_admin!

    def self.record!(incident, action, actor, request)
      AuditLogger.record!(
        action: action, auditable: incident, actor: actor, organization: incident.event.organization,
        after_data: incident.attributes.slice(
          "id", "live_pilot_run_id", "event_id", "parent_incident_id", "action", "severity", "category",
          "summary", "evidence_reference", "evidence_digest", "occurred_at"
        ), request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "The incident conflicts with an existing record"
    end
    private_class_method :error_message
  end
end
