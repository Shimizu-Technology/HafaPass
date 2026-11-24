# frozen_string_literal: true

class EmailPreference < ApplicationRecord
  normalizes :email, with: ->(value) { value.strip.downcase }
  validates :email, presence: true, uniqueness: true

  def self.blocked?(email)
    exists?(email: email.to_s.strip.downcase, all_unsubscribed: true)
  end
end
