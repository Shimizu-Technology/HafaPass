class Event < ApplicationRecord
  belongs_to :organizer_profile
  belongs_to :recurrence_parent, class_name: "Event", optional: true
  has_many :recurrence_children, class_name: "Event", foreign_key: "recurrence_parent_id", dependent: :nullify
  has_many :ticket_types, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error
  has_many :tickets, dependent: :restrict_with_error
  has_many :inventory_holds, dependent: :restrict_with_error
  has_many :promo_codes, dependent: :destroy
  has_many :guest_list_entries, dependent: :destroy
  has_many :waitlist_entries, dependent: :destroy

  RECURRENCE_RULES = %w[weekly biweekly monthly].freeze
  validates :recurrence_rule, inclusion: { in: RECURRENCE_RULES }, allow_nil: true

  enum :status, { draft: 0, published: 1, cancelled: 2, completed: 3 }
  enum :category, { nightlife: 0, concert: 1, festival: 2, dining: 3, sports: 4, other: 5 }
  enum :age_restriction, { all_ages: 0, eighteen_plus: 1, twenty_one_plus: 2 }

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true
  validates :max_capacity, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :capacity_covers_committed_inventory

  before_validation :generate_slug, if: -> { slug.blank? || title_changed? }

  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }
  scope :featured, -> { where(is_featured: true) }

  # Check if tickets are available and notify next waitlisted people
  def notify_waitlist_if_available
    ticket_types.each do |tt|
      next unless tt.available_quantity > 0

      entries = waitlist_entries
        .where(status: :waiting)
        .where("ticket_type_id = ? OR ticket_type_id IS NULL", tt.id)
        .order(:position)
        .limit(tt.available_quantity)

      entries.each do |entry|
        entry.notify!
        EmailService.send_waitlist_notification_async(entry)
      end
    end
  end

  private

  def capacity_covers_committed_inventory
    return if max_capacity.blank? || !persisted?

    committed = ticket_types.sum(:quantity_sold) + inventory_holds.current.sum(:quantity)
    errors.add(:max_capacity, "cannot be less than sold and actively held inventory") if max_capacity < committed
  end

  def generate_slug
    base_slug = title.to_s.parameterize
    self.slug = base_slug

    if Event.where(slug: self.slug).where.not(id: self.id).exists?
      self.slug = "#{base_slug}-#{SecureRandom.hex(3)}"
    end
  end
end
