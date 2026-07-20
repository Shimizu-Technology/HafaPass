# frozen_string_literal: true

class GuestOrderAccess
  PURPOSE = "guest_order_access"
  LIFETIME = 30.days

  class << self
    def issue!(order, expires_at: LIFETIME.from_now, rotate: false)
      order.with_lock do
        order.increment!(:guest_access_version) if rotate
        attributes = { guest_access_expires_at: expires_at }
        attributes[:guest_access_revoked_at] = nil if rotate
        order.update!(attributes)
      end

      SignedCredential.issue(
        namespace: PURPOSE,
        payload: { order_id: order.id, version: order.guest_access_version },
        expires_at: expires_at
      )
    end

    def find(token)
      payload = SignedCredential.verify(namespace: PURPOSE, token: token)
      return if payload.blank?

      order = Order.find_by(id: payload["order_id"] || payload[:order_id])
      version = payload["version"] || payload[:version]
      return unless order&.guest_access_valid?(version: version)

      order
    end

    def revoke!(order)
      order.with_lock do
        order.update!(
          guest_access_version: order.guest_access_version + 1,
          guest_access_revoked_at: Time.current
        )
      end
    end
  end
end
