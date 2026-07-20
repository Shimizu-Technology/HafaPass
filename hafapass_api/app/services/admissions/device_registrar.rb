# frozen_string_literal: true

module Admissions
  class DeviceRegistrar
    class RegistrationError < StandardError; end

    MAX_AUTHORIZATION = 72.hours
    EVENT_GRACE = 12.hours

    def self.call(**)
      new(**).call
    end

    def initialize(event:, user:, identifier:, name:, request: nil)
      @event = event
      @user = user
      @identifier = identifier.to_s.strip
      @name = name.to_s.strip
      @request = request
    end

    def call
      raise RegistrationError, "Device identifier is required" if identifier.blank?
      raise RegistrationError, "Device name is required" if name.blank?
      unless OrganizationAuthorization.allowed?(user: user, organization: event.organization, permission: :scan, event: event)
        raise RegistrationError, "You are not assigned to scan this event"
      end

      expires_at = authorization_expiration
      raise RegistrationError, "Scanner authorization has expired" unless expires_at > Time.current

      device = nil
      ScannerDevice.transaction do
        device = event.scanner_devices.lock.find_or_initialize_by(identifier: identifier)
        if device.persisted? && device.user_id != user.id
          raise RegistrationError, "This browser identifier is already registered to another staff member"
        end
        device.assign_attributes(
          organization: event.organization,
          user: user,
          name: name,
          status: :active,
          authorization_expires_at: expires_at,
          revoked_at: nil,
          last_seen_at: Time.current
        )
        device.save!
        AuditLogger.record!(
          action: "scanner_device.authorized",
          auditable: device,
          actor: user,
          organization: event.organization,
          after_data: {
            event_id: event.id,
            name: device.name,
            authorization_expires_at: device.authorization_expires_at
          },
          request: request
        )
      end
      device
    rescue ActiveRecord::RecordInvalid => e
      raise RegistrationError, e.record.errors.full_messages.to_sentence
    end

    private

    attr_reader :event, :user, :identifier, :name, :request

    def authorization_expiration
      now = Time.current
      event_limit = (event.ends_at || event.starts_at || now) + EVENT_GRACE
      hard_limit = [event_limit, now + MAX_AUTHORIZATION].min
      membership = event.organization.organization_memberships.effective(now).find_by(user: user)
      return now unless membership

      path_expirations = []
      membership_permissions = OrganizationAuthorization::PERMISSIONS.fetch(membership.role.to_sym, [])
      unless OrganizationAuthorization::ASSIGNMENT_REQUIRED_ROLES.include?(membership.role)
        path_expirations << [hard_limit, membership.expires_at].compact.min if membership_permissions.include?(:scan)
      end

      event.event_staff_assignments.effective(now).where(user: user).find_each do |assignment|
        permissions = OrganizationAuthorization::EVENT_ASSIGNMENT_PERMISSIONS.fetch(assignment.role.to_sym, [])
        next unless permissions.include?(:scan)

        path_expirations << [hard_limit, membership.expires_at, assignment.expires_at].compact.min
      end
      path_expirations.max || now
    end
  end
end
