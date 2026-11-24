# frozen_string_literal: true

# Append-only application ledger; never rewrite a previous consent decision.
class EmailConsent < ApplicationRecord
  VERSION = "event-alerts-v1"
  belongs_to :organization, optional: true
  validates :email, :scope, :action, :version, :source, presence: true
  before_update { throw :abort }
  before_destroy { throw :abort }

  def self.record!(email:, scope:, action:, source:, organization: nil, request: nil)
    create!(email: email.strip.downcase, scope: scope, action: action, source: source,
      organization: organization, version: VERSION,
      ip: request&.remote_ip, user_agent: request&.user_agent.to_s.first(500))
  end
end
