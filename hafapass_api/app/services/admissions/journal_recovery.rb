# frozen_string_literal: true

module Admissions
  # An authorized manager attests to the physical gate record. Client clocks
  # cannot prove when an offline scan happened. Server-issued download/lease
  # evidence bounds the review; it does not make the journal tamper-proof.
  class JournalRecovery < Reconciler
    MAX_AGE = 48.hours

    def self.call(**)
      AuditContext.set(fail_open: false) { new(**).call }
    end

    def initialize(reason:, window_start:, window_end:, **options)
      super(**options)
      @reason = reason.to_s.strip
      @window_start = Time.iso8601(window_start.to_s)
      @window_end = Time.iso8601(window_end.to_s)
    rescue ArgumentError
      raise SyncError, "Review requires an explicit ISO-8601 historical window"
    end

    def call
      AdmissionAction.transaction do
        device.lock!
        results = super
        # Required privileged audit: failure rolls back check-ins, actions and
        # sequence updates together. Normal door scanning remains fail-open.
        AuditLogger.record!(action: "scanner_device.journal_recovered", auditable: device,
          actor: actor, organization: device.organization, event: device.event, request: request,
          metadata: { reason: @reason, window_start: @window_start.iso8601(6),
            window_end: @window_end.iso8601(6), entry_count: results.size,
            original_user_id: device.user_id, action_uuids: results.map { |result| result.action.action_uuid } })
        results
      end
    end

    private

    def validate_authorization!
      %i[scan manage_staff manage_attendees].each do |permission|
        unless OrganizationAuthorization.allowed?(user: actor, organization: device.organization,
            permission: permission, event: device.event)
          raise SyncError, "Current event manager authority is required for journal recovery"
        end
      end
    end

    def validate_batch!
      super
      unless @reason.length.between?(12, 500)
        raise SyncError, "Describe the independently reviewed gate evidence (12–500 characters)"
      end
      unless @window_start >= Time.current - MAX_AGE && @window_end <= Time.current &&
          @window_end > @window_start && @window_end - @window_start <= 24.hours
        raise SyncError, "Review window must be within the last 48 hours and at most 24 hours long"
      end
      normalized_actions.each do |input|
        unless input[:kind] == "admit" && input[:source] == "offline"
          raise SyncError, "Recovery only accepts reviewed offline admissions; reversals require normal manager controls"
        end
        validate_evidence!(input)
      end
    end

    def validate_evidence!(input)
      manifest = manifest_for(input.fetch(:manifest_version))
      raise SyncError, "No known manifest for this event" unless manifest

      # Do not accept an arbitrary event manifest never issued to this device.
      downloads = AuditLog.where(auditable: device, action: "scanner_device.manifest_downloaded")
        .where("after_data ->> 'manifest_version' = ?", manifest.version.to_s).order(:id)
      evidence = downloads.filter_map do |download|
        downloaded_at = Time.iso8601(download.after_data.fetch("downloaded_at"))
        lease = download.after_data["lease_expires_at"]
        # Legacy downloads did not snapshot the lease. Use the recorded grant
        # preceding that download, never today's renewed authorization.
        lease ||= AuditLog.where(auditable: device, action: "scanner_device.authorized")
          .where("occurred_at <= ?", download.occurred_at).order(:id).last&.after_data&.fetch("authorization_expires_at", nil)
        next unless lease

        [downloaded_at, Time.iso8601(lease), download]
      rescue KeyError, ArgumentError, TypeError
        nil
      end
      occurred = input.fetch(:occurred_at)
      stop = [manifest.expires_at, device.revoked_at].compact.min
      valid = occurred >= @window_start && occurred < @window_end && occurred >= manifest.generated_at &&
        occurred >= device.created_at && occurred < stop && evidence.any? do |downloaded, lease, download|
          next false unless occurred >= downloaded && occurred < lease

          @authorities ||= {}
          authority = @authorities[download.id] ||= HistoricalScanAuthority.new(device: device, download: download)
          authority.allowed?(at: occurred)
        end
      raise SyncError, "Scan is outside the reviewed server-issued device/manifest window; retain it for manual investigation" unless valid

      entry = entries_for(manifest)[input[:ticket_id].to_i]
      unless entry && entry["state"] == "valid" && secure_equal?(entry["credential_hash"], input[:credential_hash])
        raise SyncError, "Recovery requires a ticket eligible in the known downloaded manifest"
      end
    end

    def validate_replay!(existing, input)
      unless existing.ticket_id == input[:ticket_id].to_i && existing.manifest_version == input[:manifest_version] &&
          existing.occurred_at == input[:occurred_at]
        raise SyncError, "Recovery retry must preserve the original ticket, manifest and scan time"
      end
      super
    end
  end
end
