# frozen_string_literal: true

class EventSeries < ApplicationRecord
  include OperationalAuditable

  REVENUE_SHARE_BASES = %w[
    admissions_net_proceeds
    admissions_gross
    admissions_net_after_processing
    all_net_proceeds
  ].freeze

  audits_operations :event_series,
    fields: %w[organization_id status revenue_share_bps revenue_share_base revenue_share_includes_door_cash],
    observe: %w[name slug description revenue_share_label primary_share_label]

  belongs_to :organization
  has_many :event_series_memberships, -> { order(:position, :id) }, dependent: :destroy
  has_many :events, through: :event_series_memberships

  enum :status, { draft: 0, active: 1, completed: 2, archived: 3 }

  validates :name, presence: true, length: { maximum: 200 }
  validates :slug, presence: true,
    uniqueness: { scope: :organization_id },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/, message: "must use lowercase letters, numbers, and hyphens" }
  validates :revenue_share_bps, numericality: { only_integer: true, in: 0..10_000 }, allow_nil: true
  validates :revenue_share_base, inclusion: { in: REVENUE_SHARE_BASES }

  before_validation :normalize_or_generate_slug

  private

  def normalize_or_generate_slug
    if slug.present?
      self.slug = slug.to_s.parameterize
    elsif name.present?
      base = name.to_s.parameterize.presence || "series"
      candidate = base
      suffix = 2
      while organization_id.present? && EventSeries.where(organization_id: organization_id).where.not(id: id).exists?(slug: candidate)
        candidate = "#{base}-#{suffix}"
        suffix += 1
      end
      self.slug = candidate
    end
  end
end
