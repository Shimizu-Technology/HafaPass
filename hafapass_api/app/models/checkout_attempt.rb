# frozen_string_literal: true

# A permanent tombstone fences rejected keys, including requests which reached
# the application later than their retry. No buyer payload or raw key is stored.
class CheckoutAttempt < ApplicationRecord
  LEASE_DURATION = 2.minutes
  Claim = Data.define(:attempt, :lease_token)
  class Conflict < StandardError
    attr_reader :recovery_required

    def initialize(message, recovery_required: true)
      @recovery_required = recovery_required
      super(message)
    end
  end

  belongs_to :order, optional: true
  attr_readonly :checkout_key_digest, :request_digest
  enum :status, { processing: 0, rejected: 1, reserved: 2 }, prefix: true
  validates :checkout_key_digest, :request_digest, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :preserve_final_state, on: :update

  def self.claim!(key_digest:, request_digest:)
    token = SecureRandom.hex(32)
    attempt = create_or_find_by!(checkout_key_digest: key_digest) do |record|
      record.assign_attributes(request_digest: request_digest, lease_token_digest: Digest::SHA256.hexdigest(token),
        lease_expires_at: LEASE_DURATION.from_now)
    end
    attempt.with_lock do
      unless attempt.request_digest == request_digest
        raise Conflict, "Checkout recovery does not match this request"
      end
      # Import an existing pre-journal order without releasing its reservation.
      previous = Order.find_by(checkout_key_digest: key_digest) unless attempt.order_id
      if previous
        raise Conflict, "Checkout recovery does not match this request" unless previous.checkout_request_digest == request_digest

        attempt.reserve!(previous)
      end
      return Claim.new(attempt: attempt, lease_token: nil) if attempt.order_id
      if attempt.status_rejected?
        raise Conflict.new("This checkout was rejected; review the details and start again", recovery_required: false)
      end
      if attempt.lease_expires_at&.future? && !attempt.owns_token?(token)
        raise Conflict, "Checkout is still in progress; retry the original checkout request"
      end

      attempt.update!(lease_token_digest: Digest::SHA256.hexdigest(token), lease_expires_at: LEASE_DURATION.from_now)
      Claim.new(attempt: attempt, lease_token: token)
    end
  end

  # Called while holding this row lock throughout the LOCAL reservation only.
  # A takeover or rejection cannot race the atomic order attachment.
  def verify_owner!(token)
    return if status_processing? && owns_token?(token) && lease_expires_at&.future?

    raise Conflict.new("Checkout ownership changed; retry the original checkout request",
      recovery_required: !status_rejected?)
  end

  def reserve!(reserved_order)
    update!(order: reserved_order, status: :reserved, lease_token_digest: nil, lease_expires_at: nil)
  end

  def reject!(token)
    with_lock do
      return false unless status_processing? && owns_token?(token) && order_id.nil?

      update!(status: :rejected, lease_token_digest: nil, lease_expires_at: nil)
      true
    end
  end

  def owns_token?(token)
    token.present? && lease_token_digest.present? &&
      ActiveSupport::SecurityUtils.secure_compare(lease_token_digest, Digest::SHA256.hexdigest(token))
  end

  private

  def preserve_final_state
    if %w[rejected reserved].include?(status_in_database) &&
        %w[status order_id lease_token_digest lease_expires_at].any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "Final checkout identity cannot be changed")
    end
  end
end
