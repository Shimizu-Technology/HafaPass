# frozen_string_literal: true

class Venue < ApplicationRecord
  has_many :events, dependent: :restrict_with_error
  has_many :venue_layouts, dependent: :restrict_with_error

  validates :name, :slug, :address, :village, presence: true
  validates :slug, uniqueness: true
  validates :website_url, format: URI::DEFAULT_PARSER.make_regexp(%w[http https]), allow_blank: true

  before_validation :generate_slug, if: -> { slug.blank? || name_changed? }
  scope :published, -> { where(active: true) }

  private

  def generate_slug
    base = name.to_s.parameterize.presence || "venue"
    candidate = base
    suffix = 2
    while Venue.where.not(id: id).exists?(slug: candidate)
      candidate = "#{base}-#{suffix}"
      suffix += 1
    end
    self.slug = candidate
  end
end
