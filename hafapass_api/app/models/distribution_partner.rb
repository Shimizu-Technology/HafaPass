# frozen_string_literal: true

class DistributionPartner < ApplicationRecord
  has_many :distribution_links, dependent: :restrict_with_error
  enum :kind, { hotel: 0, concierge: 1, tourism: 2, ambros: 3, promoter: 4 }
  validates :name, :slug, presence: true
  validates :slug, uniqueness: true
  validates :contact_email, format: URI::MailTo::EMAIL_REGEXP, allow_blank: true
  validates :website_url, format: URI::DEFAULT_PARSER.make_regexp(%w[http https]), allow_blank: true
  before_validation :generate_slug, if: -> { slug.blank? || name_changed? }

  private

  def generate_slug
    base = name.to_s.parameterize.presence || "partner"
    self.slug = base
    self.slug = "#{base}-#{SecureRandom.hex(3)}" if DistributionPartner.where.not(id: id).exists?(slug: slug)
  end
end
