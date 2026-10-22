# frozen_string_literal: true

class PrivacyRequestAccess
  PURPOSE = "privacy_request_export"

  def self.token(privacy_request)
    SignedCredential.issue(namespace: PURPOSE, payload: { privacy_request_id: privacy_request.id },
      expires_at: 7.days.from_now)
  end

  def self.find(token)
    payload = SignedCredential.verify(namespace: PURPOSE, token: token)
    request = PrivacyRequest.find_by(id: payload&.fetch("privacy_request_id", nil))
    request if request&.kind == "access" && request.status == "completed"
  end

  def self.url(privacy_request)
    "#{PublicSiteUrl.api || 'http://localhost:3000'}/api/v1/privacy_export?token=#{ERB::Util.url_encode(token(privacy_request))}"
  end
end
