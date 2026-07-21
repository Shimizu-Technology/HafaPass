# frozen_string_literal: true

require "digest"

class EventWaiver < ApplicationRecord
  belongs_to :event
  has_many :waiver_acceptances, dependent: :restrict_with_error

  validates :title, :body, :version, :content_digest, presence: true
  validates :version, uniqueness: { scope: :event_id }

  before_validation :assign_content_digest
  validate :accepted_content_is_immutable

  scope :published, -> { where(active: true).order(:id) }

  private

  def assign_content_digest
    self.content_digest = Digest::SHA256.hexdigest(JSON.generate({ title: title.to_s, body: body.to_s, version: version.to_s }))
  end

  def accepted_content_is_immutable
    return unless persisted? && (will_save_change_to_title? || will_save_change_to_body? || will_save_change_to_version?)
    return unless waiver_acceptances.exists?

    errors.add(:base, "Accepted waiver content is immutable; create a new version")
  end
end
