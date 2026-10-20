# frozen_string_literal: true

# Deployed environments must name their public site; links in emails, share
# previews and sitemaps never fall back to localhost or a hardcoded domain.
Rails.application.config.after_initialize do
  PublicSiteUrl.validate!
end
