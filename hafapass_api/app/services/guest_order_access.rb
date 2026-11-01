# frozen_string_literal: true

class GuestOrderAccess
  PURPOSE = "guest_order_access"
  LIFETIME = 30.days
  AFTER_EVENT = 7.days

  class << self
    # Links from confirmation and event emails must still open on event day,
    # even for an event months away: at least 30 days, and until a week after
    # the event ends.
    def default_expires_at(order, from: Time.current)
      event_end = order.event&.ends_at || order.event&.starts_at
      [from + LIFETIME, event_end && (event_end + AFTER_EVENT)].compact.max
    end

    # A new link never shortens the order's access window, so issuing one
    # cannot expire links the buyer already holds.
    def issue!(order, expires_at: nil, rotate: false)
      expires_at ||= default_expires_at(order)
      order.with_lock do
        order.increment!(:guest_access_version) if rotate
        attributes = { guest_access_expires_at: [order.guest_access_expires_at, expires_at].compact.max }
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
