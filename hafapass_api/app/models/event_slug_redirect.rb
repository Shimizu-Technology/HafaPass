# frozen_string_literal: true

# A link name an event used to have. Public lookups resolve it to the event's
# current link.
class EventSlugRedirect < ApplicationRecord
  belongs_to :event

  validates :slug, presence: true, uniqueness: true
end
