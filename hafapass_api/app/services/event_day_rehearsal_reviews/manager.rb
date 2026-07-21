# frozen_string_literal: true

module EventDayRehearsalReviews
  class Manager
    class ReviewError < StandardError; end

    SNAPSHOT_FIELDS = %i[
      pilot_validation_review_id evidence_reference evidence_digest event_state_digest application_revision
      manifest_results device_results scan_results incident_drills door_sales_results reconciliation_results
      assignments controls effective_at expires_at
    ].freeze

    def self.submit!(event:, attributes:, actor:, request: nil)
      review = nil
      event.with_lock do
        validation = current_validation(event)
        raise ReviewError, "A current Gate F validation approval is required first" unless validation
        if EventDayRehearsal.active_approval(event, validation_approval: validation)
          raise ReviewError, "Revoke the current Gate G rehearsal approval before submitting another"
        end
        if EventDayRehearsal.pending_submission(event)
          raise ReviewError, "Decide the current Gate G rehearsal submission before submitting another"
        end

        snapshot = normalize_snapshot(attributes.to_h.symbolize_keys.slice(*SNAPSHOT_FIELDS))
        snapshot[:pilot_validation_review_id] = validation.id
        snapshot[:event_state_digest] = validation.event_state_digest
        snapshot[:application_revision] = PilotReadiness.application_revision
        review = event.event_day_rehearsal_reviews.create!(
          snapshot.merge(decision: :submission, actor_user: actor)
        )
        record!(review, "event_day_rehearsal.submitted", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.approve!(submission:, actor:, request: nil)
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor, approving: true)
        raise ReviewError, "The rehearsal evidence window is not yet effective" if submission.effective_at > Time.current
        raise ReviewError, "The rehearsal evidence window has expired" if submission.expires_at <= Time.current
        state_digest = PilotReadiness.event_state_digest(submission.event)
        validation = current_validation(submission.event, state_digest: state_digest)
        unless validation&.id == submission.pilot_validation_review_id &&
            submission.event_state_digest == state_digest &&
            submission.application_revision == PilotReadiness.application_revision
          raise ReviewError, "Gate F, application, or event configuration changed; submit new rehearsal evidence"
        end
        if EventDayRehearsal.active_approval(submission.event, validation_approval: validation)
          raise ReviewError, "Revoke the current Gate G rehearsal approval before approving another"
        end

        review = submission.event.event_day_rehearsal_reviews.create!(snapshot(submission).merge(
          decision: :approval, parent_review: submission, actor_user: actor
        ))
        record!(review, "event_day_rehearsal.approved", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.reject!(submission:, actor:, reason:, request: nil)
      raise ReviewError, "A specific rejection reason is required" if reason.to_s.strip.blank?
      review = nil
      submission.event.with_lock do
        submission.reload
        validate_open_submission!(submission, actor: actor)
        review = submission.event.event_day_rehearsal_reviews.create!(snapshot(submission).merge(
          decision: :rejection, parent_review: submission, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "event_day_rehearsal.rejected", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.revoke!(approval:, actor:, reason:, request: nil)
      raise ReviewError, "A specific revocation reason is required" if reason.to_s.strip.blank?
      review = nil
      approval.event.with_lock do
        approval.reload
        raise ReviewError, "Only an approval can be revoked" unless approval.decision_approval?
        raise ReviewError, "This approval has already been revoked" if approval.revoked?
        review = approval.event.event_day_rehearsal_reviews.create!(snapshot(approval).merge(
          decision: :revocation, parent_review: approval, actor_user: actor, reason: reason.to_s.strip
        ))
        record!(review, "event_day_rehearsal.revoked", actor, request)
      end
      review
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise ReviewError, error_message(e)
    end

    def self.current_validation(event, state_digest: nil)
      readiness = PilotReadiness.active_approval(event, state_digest: state_digest)
      PilotValidation.active_approval(
        event, readiness_approval: readiness, state_digest: state_digest
      ) if readiness
    end
    private_class_method :current_validation

    def self.validate_open_submission!(submission, actor:, approving: false)
      raise ReviewError, "Only a submission can be decided" unless submission.decision_submission?
      if submission.child_reviews.where(decision: [:approval, :rejection]).exists?
        raise ReviewError, "This rehearsal submission already has a decision"
      end
      if approving && submission.actor_user_id == actor.id
        raise ReviewError, "The submitter cannot approve their own rehearsal evidence"
      end
    end
    private_class_method :validate_open_submission!

    def self.snapshot(review)
      review.attributes.symbolize_keys.slice(*SNAPSHOT_FIELDS)
    end
    private_class_method :snapshot

    def self.normalize_snapshot(snapshot)
      snapshot[:manifest_results] = normalize_manifest(snapshot[:manifest_results])
      snapshot[:device_results] = normalize_devices(snapshot[:device_results])
      snapshot[:scan_results] = normalize_boolean_matrix(snapshot[:scan_results], EventDayRehearsalReview::SCAN_KEYS)
      snapshot[:incident_drills] = normalize_nested(
        snapshot[:incident_drills], EventDayRehearsalReview::INCIDENT_KEYS,
        EventDayRehearsalReview::INCIDENT_FIELDS
      )
      snapshot[:door_sales_results] = normalize_door_sales(snapshot[:door_sales_results])
      snapshot[:reconciliation_results] = normalize_reconciliation(snapshot[:reconciliation_results])
      snapshot[:assignments] = normalize_nested(
        snapshot[:assignments], EventDayRehearsalReview::ASSIGNMENT_KEYS,
        EventDayRehearsalReview::ASSIGNMENT_FIELDS
      )
      snapshot[:controls] = normalize_boolean_matrix(snapshot[:controls], EventDayRehearsalReview::CONTROL_KEYS)
      snapshot
    end
    private_class_method :normalize_snapshot

    def self.normalize_manifest(value)
      result = safe_hash(value).slice(*EventDayRehearsalReview::MANIFEST_FIELDS)
      %w[version ticket_count].each { |field| result[field] = normalize_integer(result[field]) if result.key?(field) }
      if result.key?("signature_verified_on_every_device")
        result["signature_verified_on_every_device"] = boolean(result["signature_verified_on_every_device"])
      end
      result
    end
    private_class_method :normalize_manifest

    def self.normalize_devices(value)
      devices = value.is_a?(Array) ? value : []
      devices.first(10).map do |device|
        result = safe_hash(device).slice(*EventDayRehearsalReview::DEVICE_FIELDS)
        %w[physical_device manifest_signature_verified offline_mode_completed].each do |field|
          result[field] = boolean(result[field]) if result.key?(field)
        end
        %w[
          reconnect_order queued_actions_before_sync queued_actions_after_sync conflicts_observed
          immediate_feedback_p95_ms
        ].each { |field| result[field] = normalize_integer(result[field]) if result.key?(field) }
        result
      end
    end
    private_class_method :normalize_devices

    def self.normalize_door_sales(value)
      result = normalize_nested(
        value, EventDayRehearsalReview::DOOR_CHANNELS, EventDayRehearsalReview::DOOR_SALE_FIELDS
      )
      card = result["card_present"]
      card["no_blind_retry_confirmed"] = boolean(card["no_blind_retry_confirmed"]) if card&.key?("no_blind_retry_confirmed")
      result
    end
    private_class_method :normalize_door_sales

    def self.normalize_reconciliation(value)
      result = safe_hash(value).slice(*EventDayRehearsalReview::RECONCILIATION_FIELDS)
      %w[all_card_attempts_resolved all_devices_synced].each do |field|
        result[field] = boolean(result[field]) if result.key?(field)
      end
      (EventDayRehearsalReview::RECONCILIATION_FIELDS - %w[all_card_attempts_resolved all_devices_synced]).each do |field|
        result[field] = normalize_integer(result[field]) if result.key?(field)
      end
      result
    end
    private_class_method :normalize_reconciliation

    def self.normalize_boolean_matrix(value, keys)
      safe_hash(value).slice(*keys).transform_values { |item| boolean(item) }
    end
    private_class_method :normalize_boolean_matrix

    def self.normalize_nested(value, keys, fields)
      safe_hash(value).slice(*keys).transform_values do |item|
        safe_hash(item).slice(*fields)
      end
    end
    private_class_method :normalize_nested

    def self.boolean(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
    private_class_method :boolean

    def self.safe_hash(value)
      value.respond_to?(:to_h) ? value.to_h.stringify_keys : {}
    end
    private_class_method :safe_hash

    def self.normalize_integer(value)
      Integer(value, exception: false) || value
    end
    private_class_method :normalize_integer

    def self.record!(review, action, actor, request)
      device_summary = review.device_results.map do |device|
        device.to_h.slice(
          "identifier", "model", "os_version", "browser", "browser_version", "physical_device",
          "manifest_signature_verified", "offline_mode_completed", "reconnect_order", "queued_actions_after_sync",
          "immediate_feedback_p95_ms"
        )
      end
      incident_summary = review.incident_drills.transform_values { |result| result.to_h.slice("status") }
      assignment_summary = review.assignments.transform_values { |result| { "assigned" => result.to_h.present? } }
      AuditLogger.record!(
        action: action, auditable: review, actor: actor, organization: review.event.organization,
        after_data: review.attributes.slice(
          "id", "event_id", "pilot_validation_review_id", "parent_review_id", "actor_user_id", "decision",
          "evidence_reference", "evidence_digest", "event_state_digest", "application_revision", "manifest_results",
          "scan_results", "door_sales_results", "reconciliation_results", "controls", "effective_at", "expires_at",
          "reason"
        ).merge("device_results" => device_summary, "incident_drills" => incident_summary,
          "assignments" => assignment_summary),
        request: request
      )
    end
    private_class_method :record!

    def self.error_message(error)
      return error.record.errors.full_messages.to_sentence if error.respond_to?(:record)

      error.message.presence || "Event-day rehearsal evidence conflicts with an existing decision"
    end
    private_class_method :error_message
  end
end
