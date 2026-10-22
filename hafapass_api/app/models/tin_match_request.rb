# frozen_string_literal: true

class TinMatchRequest < ApplicationRecord
  belongs_to :organizer_tax_information
  validates :account_reference, presence: true, uniqueness: true, length: { maximum: 20 }
end
