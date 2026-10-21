# frozen_string_literal: true

module ApprovedImageUrl
  MESSAGE = "must be a completed HåfaPass image upload on the approved asset host"

  def self.valid?(url, organization_id:)
    return false unless well_formed?(url) && organization_id.present?

    ImageUploadReceipt.where(organization_id: organization_id, public_url: url)
      .where.not(completed_at: nil).exists?
  end

  def self.well_formed?(url)
    return false unless url.is_a?(String) && url.length <= 2048

    uri = URI.parse(url)
    uri.is_a?(URI::HTTPS) && uri.host == S3Service.public_asset_host &&
      uri.userinfo.nil? && uri.port == 443 && uri.query.nil? && uri.fragment.nil? &&
      uri.path.start_with?("/uploads/")
  rescue URI::InvalidURIError
    false
  end
end
