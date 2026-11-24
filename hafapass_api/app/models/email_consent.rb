# frozen_string_literal: true

# Append-only application ledger; never rewrite a previous consent decision.
class EmailConsent < ApplicationRecord
  VERSION = "event-alerts-v1"
  belongs_to :organization, optional: true
  validates :email, :scope, :action, :version, :source, presence: true
  before_update { throw :abort }
  before_destroy { throw :abort }

  def self.version_for(scope:, source:)
    "#{scope == 'organizer' ? 'organizer' : 'event-alerts'}-#{source}-v1"
  end

  def self.record!(email:, scope:, action:, source:, organization: nil, request: nil, ip: nil, user_agent: nil)
    create!(email: email.strip.downcase, scope: scope, action: action, source: source,
      organization: organization, version: version_for(scope: scope, source: source),
      ip: request&.remote_ip || ip, user_agent: (request&.user_agent || user_agent).to_s.first(500))
  end
end
