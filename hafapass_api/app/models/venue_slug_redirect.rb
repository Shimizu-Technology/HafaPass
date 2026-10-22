# frozen_string_literal: true

# A link name a venue used to have. Public lookups resolve it to the venue's
# current link.
class VenueSlugRedirect < ApplicationRecord
  belongs_to :venue

  validates :slug, presence: true, uniqueness: true
end
