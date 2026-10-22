# frozen_string_literal: true

class LegalHold < ApplicationRecord
  SCOPES = %w[organization event order user buyer_email].freeze

  belongs_to :placed_by, class_name: "User"
  belongs_to :released_by, class_name: "User", optional: true

  scope :active, -> { where(released_at: nil) }

  validates :scope_type, inclusion: { in: SCOPES }
  validates :scope_value, presence: true
  validates :scope_value, uniqueness: { scope: :scope_type, conditions: -> { active },
    message: "already has an active hold" }
  validates :reason, presence: true, length: { minimum: 10, maximum: 2_000 }
  validate :valid_scope

  before_validation do
    self.scope_value = scope_value.to_s.strip.downcase if scope_type == "buyer_email"
  end

  def release!(actor:, request: nil)
    self.class.with_retention_lock do
      with_lock do
        return if released_at?

        update!(released_at: Time.current, released_by: actor)
        AuditLogger.record!(action: "legal_hold.released", auditable: self, actor: actor,
          metadata: { scope_type: scope_type, scope_value: scope_type == "buyer_email" ? "[redacted]" : scope_value },
          request: request)
      end
    end
  end

  # The global key serializes broad email/user holds with S3 deletion. The
  # organization key also fences export objects whose path identifies an org.
  def self.with_retention_lock(organization_id: nil)
    transaction do
      connection.execute("SELECT pg_advisory_xact_lock(728314, 0)")
      if organization_id
        bind = ActiveRecord::Relation::QueryAttribute.new("organization_id", Integer(organization_id),
          ActiveRecord::Type::Integer.new)
        connection.exec_query("SELECT pg_advisory_xact_lock(728314, $1)", "Retention organization lock", [bind])
      end
      yield
    end
  end

  def self.place!(scope_type:, scope_value:, reason:, actor:, request: nil)
    organization_id = case scope_type.to_s
    when "organization" then scope_value.to_i
    when "event" then Event.where(id: scope_value).pick(:organization_id)
    when "order" then Order.joins(:event).where(id: scope_value).pick("events.organization_id")
    end
    with_retention_lock(organization_id: organization_id) do
      hold = create!(scope_type: scope_type, scope_value: scope_value, reason: reason, placed_by: actor)
      AuditLogger.record!(action: "legal_hold.placed", auditable: hold, actor: actor,
        metadata: { scope_type: hold.scope_type, scope_value: scope_type == "buyer_email" ? "[redacted]" : hold.scope_value },
        request: request)
      hold
    end
  end

  def self.for_order?(order)
    active.where(scope_type: "organization", scope_value: order.event.organization_id.to_s)
      .or(active.where(scope_type: "event", scope_value: order.event_id.to_s))
      .or(active.where(scope_type: "order", scope_value: order.id.to_s))
      .or(active.where(scope_type: "user", scope_value: order.user_id.to_s))
      .or(active.where(scope_type: "buyer_email", scope_value: order.buyer_email.to_s.downcase)).exists?
  end

  def self.for_user?(user)
    active.where(scope_type: "user", scope_value: user.id.to_s)
      .or(active.where(scope_type: "buyer_email", scope_value: user.email.to_s.downcase)).exists? ||
      Order.where(user_id: user.id).includes(:event).any? { |order| for_order?(order) }
  end

  private

  def valid_scope
    return if scope_type.blank? || scope_value.blank?

    if scope_type == "buyer_email"
      errors.add(:scope_value, "must be an email") unless URI::MailTo::EMAIL_REGEXP.match?(scope_value)
    elsif !scope_value.match?(/\A[1-9]\d*\z/) ||
        !scope_type.classify.constantize.exists?(id: scope_value.to_i)
      errors.add(:scope_value, "must identify an existing #{scope_type}")
    end
  end
end
