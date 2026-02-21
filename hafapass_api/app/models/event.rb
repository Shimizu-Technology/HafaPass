class Event < ApplicationRecord
  belongs_to :organizer_profile
  belongs_to :recurrence_parent, class_name: 'Event', optional: true
  has_many :recurrence_children, class_name: 'Event', foreign_key: 'recurrence_parent_id', dependent: :nullify
  has_many :ticket_types, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :tickets, dependent: :destroy
  has_many :promo_codes, dependent: :destroy
  has_many :guest_list_entries, dependent: :destroy

  RECURRENCE_RULES = %w[weekly biweekly monthly].freeze
  validates :recurrence_rule, inclusion: { in: RECURRENCE_RULES }, allow_nil: true

  enum :status, { draft: 0, published: 1, cancelled: 2, completed: 3 }
  enum :category, { nightlife: 0, concert: 1, festival: 2, dining: 3, sports: 4, other: 5 }
  enum :age_restriction, { all_ages: 0, eighteen_plus: 1, twenty_one_plus: 2 }

  validates :title, presence: true
  validates :slug, presence: true, uniqueness: true

  before_validation :generate_slug, if: -> { slug.blank? || title_changed? }

  scope :published, -> { where(status: :published) }
  scope :upcoming, -> { where("starts_at > ?", Time.current) }
  scope :past, -> { where("starts_at <= ?", Time.current) }
  scope :featured, -> { where(is_featured: true) }

  private

  def generate_slug
    base_slug = title.to_s.parameterize
    self.slug = base_slug

    if Event.where(slug: self.slug).where.not(id: self.id).exists?
      self.slug = "#{base_slug}-#{SecureRandom.hex(3)}"
    end
  end
end
