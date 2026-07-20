# frozen_string_literal: true

module PublicSiteUrl
  DEFAULT = "https://hafapass.com"

  def self.base
    ENV.fetch("PUBLIC_WEB_URL", DEFAULT).delete_suffix("/")
  end

  def self.event(event)
    "#{base}/events/#{event.slug}"
  end
end
