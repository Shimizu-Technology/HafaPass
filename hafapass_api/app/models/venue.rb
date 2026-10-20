# frozen_string_literal: true

class Venue < ApplicationRecord
  include PublicSlug

  has_many :events, dependent: :restrict_with_error
  has_many :venue_layouts, dependent: :restrict_with_error
  # Retired links mean nothing once the venue itself is gone.
  has_many :slug_redirects, class_name: "VenueSlugRedirect", dependent: :delete_all
  public_slug_redirects :slug_redirects

  validates :name, :slug, :address, :village, presence: true
  validates :slug, uniqueness: { message: "is already used by another venue" }, unless: :slug_chosen?
  validate :chosen_slug_is_available, if: :slug_chosen?
  validates :website_url, format: URI::DEFAULT_PARSER.make_regexp(%w[http https]), allow_blank: true

  # The link is generated from the name once. Renaming a venue keeps its
  # link; an admin who sets a new link name retires the old one as a redirect.
  before_validation :assign_slug
  scope :published, -> { where(active: true) }

  private

  def assign_slug
    @slug_chosen = slug_changed? && slug.present? && slug != @generated_slug
    if @slug_chosen
      self.slug = self.class.normalize_public_slug(slug)
    elsif slug.blank?
      self.slug = @generated_slug = unique_generated_slug(name, fallback: "venue")
    end
  end

  def slug_chosen?
    @slug_chosen == true
  end

  def generated_slug_source
    [name, "venue"]
  end

  def chosen_slug_is_available
    problem = self.class.public_slug_problem(slug, record: self)
    errors.add(:slug, problem) if problem
  end
end
