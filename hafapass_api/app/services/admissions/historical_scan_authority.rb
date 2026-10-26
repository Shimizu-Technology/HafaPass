# frozen_string_literal: true

module Admissions
  # A download proves the initial grant. Immutable changes describe subsequent
  # intervals; today's re-grant cannot authorize an earlier gap.
  class HistoricalScanAuthority
    FIELDS = %w[role status expires_at].freeze
    TYPES = %w[OrganizationMembership EventStaffAssignment].freeze

    def self.snapshot(device)
      # Download updates acquire organization -> event before writing the
      # scanner row. Reuse the same strong, FK-compatible organization lock:
      # grant writers take FOR UPDATE before changing authority or its audit.
      # Never upgrade it after owning EVENT/SCANNER; unrelated order audit
      # inserts may need a compatible organization FK KEY SHARE.
      device.organization.with_lock("FOR NO KEY UPDATE") do
        {
          version: 1, captured_at: Time.current.iso8601(6),
          audit_id: AuditLog.where(organization_id: device.organization_id).maximum(:id).to_i,
          admin: device.user.admin?,
          memberships: device.organization.organization_memberships.where(user_id: device.user_id).map { |row| grant_image(row) },
          assignments: device.event.event_staff_assignments.where(user_id: device.user_id).map { |row| grant_image(row) }
        }
      end
    end

    def self.grant_image(row)
      row.attributes.slice("id", *FIELDS).merge("expires_at" => row.expires_at&.getutc&.iso8601(6))
    end
    private_class_method :grant_image

    def initialize(device:, download:)
      @device = device
      @download = download
    end

    def allowed?(at:)
      prepare! unless @prepared
      state = @baseline.deep_dup
      @history.each do |entry|
        break if entry.occurred_at > at

        apply!(state, entry)
      end
      return false if at < @captured_at
      return true if @admin

      membership = state.fetch("OrganizationMembership").values.sole
      return false unless active?(membership, at)

      assignments = state.fetch("EventStaffAssignment").values.select { |grant| active?(grant, at) }
      role = membership.fetch("role")
      organization_grant = OrganizationAuthorization::PERMISSIONS.fetch(role.to_sym, []).include?(:scan) &&
        (!OrganizationAuthorization::ASSIGNMENT_REQUIRED_ROLES.include?(role) || assignments.any? { |grant| grant["role"] == role })
      organization_grant || assignments.any? { |grant| OrganizationAuthorization::EVENT_ASSIGNMENT_PERMISSIONS.fetch(grant["role"].to_sym, []).include?(:scan) }
    rescue KeyError, ArgumentError, TypeError, Enumerable::SoleItemExpectedError
      raise Reconciler::SyncError, "Historical staff authority is incomplete; retain the journal for investigation"
    end

    private

    def prepare!
      @captured_at = Time.iso8601(@download.after_data.fetch("downloaded_at"))
      snapshot = @download.after_data["scan_authority"]
      current = {
        "OrganizationMembership" => @device.organization.organization_memberships.where(user_id: @device.user_id).to_a,
        "EventStaffAssignment" => @device.event.event_staff_assignments.where(user_id: @device.user_id).to_a
      }
      history = AuditLog.where(organization_id: @device.organization_id, auditable_type: TYPES)
        .where("after_data ->> 'target_user_id' = ?", @device.user_id.to_s)
        .where("event_id IS NULL OR event_id = ?", @device.event_id).order(:occurred_at, :id).to_a
      if snapshot
        raise Reconciler::SyncError, "Unknown historical authority proof" unless snapshot["version"] == 1

        @captured_at = Time.iso8601(snapshot.fetch("captured_at"))
        @admin = snapshot.fetch("admin")
        raise Reconciler::SyncError, "Malformed historical authority proof" unless [true, false].include?(@admin)
        @baseline = {
          "OrganizationMembership" => index(snapshot.fetch("memberships")),
          "EventStaffAssignment" => index(snapshot.fetch("assignments"))
        }
        @history = history.select { |entry| entry.id > snapshot.fetch("audit_id") }
      else
        # Older downloads: reconstruct only when immutable before-images or
        # unchanged rows prove the initial state. Missing history fails closed.
        @admin = @device.user.admin? && @device.user.updated_at <= @captured_at
        @baseline = current.transform_values { |rows| index(rows.select { |row| row.created_at <= @captured_at }.map(&:attributes)) }
        @history = history.select { |entry| entry.occurred_at > @captured_at }
        current.each do |type, rows|
          rows.select { |row| row.created_at <= @captured_at }.each do |row|
            changes = @history.select { |entry| entry.auditable_type == type && entry.auditable_id == row.id }
            if row.updated_at > @captured_at && changes.empty?
              raise Reconciler::SyncError, "Historical staff update proof is missing"
            end
            changes.reverse_each do |entry|
              state = @baseline.fetch(type).fetch(row.id)
              check_image!(state, entry.after_data)
              @baseline.fetch(type)[row.id] = state.merge(normalize(entry.before_data.slice(*FIELDS)))
            end
          end
        end
      end
      # Detect missing/contradictory mutations instead of trusting today's row
      # to fill a historical interval. Unhandled ownership/admin changes require
      # manual investigation, never an inferred grant.
      ending = @baseline.deep_dup
      @history.each { |entry| apply!(ending, entry) }
      unless ending == current.transform_values { |rows| index(rows.map(&:attributes)) }
        raise Reconciler::SyncError, "Historical staff update proof is incomplete"
      end
      if @admin && @device.user.updated_at > @captured_at
        raise Reconciler::SyncError, "Historical administrator authority needs investigation"
      end
      @prepared = true
    end

    def index(rows)
      rows.to_h do |row|
        raise Reconciler::SyncError, "Incomplete historical grant image" if (FIELDS - row.keys).any?

        [row.fetch("id").to_i, normalize(row.slice(*FIELDS))]
      end
    end

    def normalize(state)
      state.dup.tap do |result|
        expiry = result["expires_at"]
        # Generic grant audit images retain only milliseconds. Truncate every
        # compared expiry to that precision; never round up or extend authority.
        # The immutable download snapshot itself keeps its original six digits.
        result["expires_at"] = (expiry.respond_to?(:to_time) ? expiry.to_time : Time.iso8601(expiry)).getutc.iso8601(3) if expiry
      end
    end

    def check_image!(state, image)
      unless normalize(image.slice(*FIELDS)).all? { |key, value| state[key] == value }
        raise Reconciler::SyncError, "Historical staff audit images conflict"
      end
    end

    def apply!(state, entry)
      grants = state.fetch(entry.auditable_type)
      previous = grants[entry.auditable_id]
      if previous
        check_image!(previous, entry.before_data)
        normalize(entry.after_data.slice(*FIELDS)).each do |key, value|
          if previous[key] != value && !entry.before_data.key?(key)
            raise Reconciler::SyncError, "Historical staff before-image is missing"
          end
        end
      elsif entry.action != "event_staff.assigned" || (FIELDS - entry.after_data.keys).any?
        raise Reconciler::SyncError, "Historical staff grant proof is missing"
      end
      grants[entry.auditable_id] = (previous || {}).merge(normalize(entry.after_data.slice(*FIELDS)))
    end

    def active?(grant, at)
      grant["status"] == "active" && (grant["expires_at"].nil? || Time.iso8601(grant["expires_at"]) > at)
    end
  end
end
