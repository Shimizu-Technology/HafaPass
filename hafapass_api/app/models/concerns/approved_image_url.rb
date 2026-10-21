# frozen_string_literal: true

module ApprovedImageUrl
  MESSAGE = "must be a completed HåfaPass image upload on the approved asset host"

  def self.valid?(url, organization_id:)
    return false unless url.is_a?(String) && url.length <= 2048 && organization_id.present?

    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTPS) && uri.host == S3Service.public_asset_host &&
      uri.userinfo.nil? && uri.port == 443 && uri.query.nil? && uri.fragment.nil? &&
      uri.path.start_with?("/uploads/")

    ImageUploadReceipt.where(organization_id: organization_id, public_url: url)
      .where.not(completed_at: nil).exists?
  rescue URI::InvalidURIError
    false
  end
end
