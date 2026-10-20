# frozen_string_literal: true

require "digest"

# A saved Apple Wallet pass serial or Google Wallet ticket object. Each row is
# bound to the scan credential version it carried when issued; once the ticket
# moves past that version the pass can only ever show as void.
class WalletPass < ApplicationRecord
  PROVIDERS = %w[apple google].freeze
  MAX_AUTHENTICATION_TOKENS = 10

  belongs_to :ticket
  has_many :apple_wallet_registrations, dependent: :destroy

  validates :provider, inclusion: { in: PROVIDERS }
  validates :serial_number, presence: true, length: { maximum: 200 }
  validates :scan_credential_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :apple, -> { where(provider: "apple") }
  scope :google, -> { where(provider: "google") }

  # Serials are unique per provider (database index); concurrent first
  # downloads converge on one row.
  def self.record!(provider:, serial_number:, ticket:)
    find_by(provider: provider, serial_number: serial_number) ||
      create_or_find_by!(provider: provider, serial_number: serial_number) do |record|
        record.ticket = ticket
        record.scan_credential_version = ticket.scan_credential_version
      end
  end

  def self.digest_token(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def apple?
    provider == "apple"
  end

  def google?
    provider == "google"
  end

  def state
    Wallet::PassState.new(ticket, scan_credential_version: scan_credential_version)
  end

  def authenticates?(token)
    return false if token.blank? || authentication_token_digests.blank?

    digest = self.class.digest_token(token)
    authentication_token_digests.any? { |stored| ActiveSupport::SecurityUtils.secure_compare(stored, digest) }
  end

  # Each download embeds a fresh random token. Earlier copies keep working, up
  # to a small cap, so a second device or a re-download is not locked out.
  def add_authentication_token!(token)
    digests = ([self.class.digest_token(token)] + authentication_token_digests).uniq.first(MAX_AUTHENTICATION_TOKENS)
    update!(authentication_token_digests: digests)
  end

  # Records the latest pass content. Apple's update tag (and Last-Modified)
  # advances in whole seconds so a device never misses two changes made within
  # the same second.
  def record_content!(digest)
    return false if digest == content_digest

    now = Time.current.change(usec: 0)
    now = content_updated_at + 1.second if content_updated_at && now <= content_updated_at
    update!(content_digest: digest, content_updated_at: now)
    true
  end

  def sync_pending?
    content_digest.present? && synced_digest != content_digest
  end

  def update_tag
    content_updated_at&.to_i.to_s
  end
end
