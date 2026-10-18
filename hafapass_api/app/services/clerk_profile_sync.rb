# frozen_string_literal: true

# Refresh only when the signed-in account is requested, never while listing
# unrelated users. The database lease bounds provider calls across API processes
# and retries outages without making profile availability a permission gate.
class ClerkProfileSync
  REFRESH_INTERVAL = 5.minutes

  def self.call(user)
    return user if %i[email first_name last_name].all? { |field| user.public_send(field).present? }

    checked_at = Time.current.change(nsec: 0)
    acquired = User.where(id: user.id)
      .where("clerk_profile_checked_at IS NULL OR clerk_profile_checked_at < ?", checked_at - REFRESH_INTERVAL)
      .update_all(clerk_profile_checked_at: checked_at)
    return user unless acquired == 1

    profile = ClerkIdentity.profile(user.clerk_id)
    # An unavailable provider must not erase the last saved contact information.
    if profile
      user.with_lock do
        # /users/sync remains editable contact data. Fill missing fields only;
        # a concurrent contact edit wins, and a slower expired lease cannot write.
        if user.clerk_profile_checked_at == checked_at
          attrs = profile.slice(:email, :first_name, :last_name).select do |field, value|
            user.public_send(field).blank? && value.present?
          end
          user.update!(attrs) if attrs.any?
        end
      end
    end
    user.reload
  end
end
