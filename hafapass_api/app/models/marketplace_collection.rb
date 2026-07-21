# frozen_string_literal: true

class MarketplaceCollection < ApplicationRecord
  belongs_to :created_by_user, class_name: "User"
  has_many :marketplace_collection_events, dependent: :destroy
  has_many :events, through: :marketplace_collection_events

  enum :status, { draft: 0, published: 1, archived: 2 }
  validates :title, :slug, presence: true
  validates :slug, uniqueness: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :chronological_window
  before_validation :generate_slug, if: -> { slug.blank? || title_changed? }

  scope :currently_visible, ->(at = Time.current) {
    published.where("starts_at IS NULL OR starts_at <= ?", at).where("ends_at IS NULL OR ends_at > ?", at)
  }

  def discoverable_events
    visible_ids = Event.discoverable.where(id: marketplace_collection_events.select(:event_id)).select(:id)
    Event.where(id: visible_ids).joins(:marketplace_collection_events)
      .where(marketplace_collection_events: { marketplace_collection_id: id })
      .order("marketplace_collection_events.position ASC", "events.starts_at ASC")
  end

  private

  def chronological_window
    errors.add(:ends_at, "must be after the start") if starts_at && ends_at && ends_at <= starts_at
  end

  def generate_slug
    base = title.to_s.parameterize.presence || "collection"
    self.slug = base
    self.slug = "#{base}-#{SecureRandom.hex(3)}" if MarketplaceCollection.where.not(id: id).exists?(slug: slug)
  end
end
