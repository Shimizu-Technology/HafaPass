class OgController < ApplicationController
  skip_before_action :authenticate_user!

  def event
    event = Event.publicly_visible.find_by!(slug: params[:slug])

    title = event.title
    description = (event.short_description || event.description || "Get tickets on HafaPass").truncate(160)
    image_url = event.cover_image_url || "#{PublicSiteUrl.base}/og-default.jpg"
    canonical_url = PublicSiteUrl.event(event)

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
        <meta charset="UTF-8" />
        <title>#{ERB::Util.html_escape(title)} | HafaPass</title>
        <meta name="description" content="#{ERB::Util.html_escape(description)}" />

        <meta property="og:title" content="#{ERB::Util.html_escape(title)}" />
        <meta property="og:description" content="#{ERB::Util.html_escape(description)}" />
        <meta property="og:image" content="#{ERB::Util.html_escape(image_url)}" />
        <meta property="og:url" content="#{ERB::Util.html_escape(canonical_url)}" />
        <meta property="og:type" content="website" />
        <meta property="og:site_name" content="HafaPass" />

        <meta name="twitter:card" content="summary_large_image" />
        <meta name="twitter:title" content="#{ERB::Util.html_escape(title)}" />
        <meta name="twitter:description" content="#{ERB::Util.html_escape(description)}" />
        <meta name="twitter:image" content="#{ERB::Util.html_escape(image_url)}" />

        <script>window.location.replace("#{canonical_url}");</script>
      </head>
      <body>
        <p>Redirecting to <a href="#{ERB::Util.html_escape(canonical_url)}">#{ERB::Util.html_escape(title)} on HafaPass</a>...</p>
      </body>
      </html>
    HTML

    render html: html.html_safe, content_type: "text/html"
  rescue ActiveRecord::RecordNotFound
    render html: %(<script>window.location.replace("#{PublicSiteUrl.base}/events");</script>).html_safe,
           content_type: "text/html", status: :not_found
  end
end
