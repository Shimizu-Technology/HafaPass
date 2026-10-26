# frozen_string_literal: true

class ScannerDevice < ApplicationRecord
  belongs_to :organization
  belongs_to :event
  belongs_to :user
  has_many :admission_actions, dependent: :restrict_with_error

  enum :status, { active: 0, revoked: 1 }, prefix: true

  validates :identifier, :name, :authorization_expires_at, presence: true
  validates :identifier, uniqueness: { scope: :event_id }
  validates :identifier, length: { maximum: 128 }
  validates :name, length: { maximum: 100 }
  validates :last_manifest_version, :last_sequence,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :relationships_share_organization
  before_update :lock_operational_context, if: :operational_context_changed?
  after_update :audit_operational_changes

  def effective?(at: Time.current)
    status_active? && authorization_expires_at > at && (revoked_at.nil? || revoked_at > at)
  end

  def revoke!(at: Time.current)
    update!(status: :revoked, revoked_at: at)
  end

  # Keep manifest construction, the current lease and the authority audit in
  # one transaction. Reload the device only after both parent locks are held.
  def with_manifest_lock
    self.class.transaction do
      lock_operational_context
      with_lock { yield }
    end
  end

  private

  # Every operational audit needs an organization FK key share. Own the
  # parents before UPDATE owns SCANNER, including rename/revoke/lease writes.
  def lock_operational_context
    # Exclude grant/tenant mutations without blocking an event-first order's
    # organization audit FK while we wait for EVENT.
    organization.lock!("FOR NO KEY UPDATE")
    event.lock!
  end

  def operational_context_changed?
    will_save_change_to_name? || will_save_change_to_authorization_expires_at? ||
      will_save_change_to_manifest_downloaded_at? || (will_save_change_to_status? && status_revoked?)
  end

  def audit_operational_changes
    if saved_change_to_name?
      AuditLogger.record!(action: "scanner_device.renamed", auditable: self, event: event,
        before_data: { name: name_before_last_save }, after_data: { name: name })
    end
    if saved_change_to_authorization_expires_at?
      AuditLogger.record!(action: "scanner_device.lease_updated", auditable: self, event: event,
        before_data: { lease_expires_at: authorization_expires_at_before_last_save },
        after_data: { lease_expires_at: authorization_expires_at })
    end
    if saved_change_to_manifest_downloaded_at?
      AuditLogger.record!(action: "scanner_device.manifest_downloaded", auditable: self, event: event,
        after_data: { manifest_version: last_manifest_version, downloaded_at: manifest_downloaded_at.iso8601(6),
          lease_expires_at: authorization_expires_at.iso8601(6), scan_authority: Admissions::HistoricalScanAuthority.snapshot(self) })
    end
    if saved_change_to_status? && status_revoked?
      AuditLogger.record!(action: "scanner_device.revoked", auditable: self, event: event,
        before_data: { status: status_before_last_save }, after_data: { status: status })
    end
  end

  def relationships_share_organization
    return if event.nil? || event.organization_id == organization_id

    errors.add(:event, "must belong to the same organization")
  end
end
