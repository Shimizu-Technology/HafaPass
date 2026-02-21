class SitemapsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    @events = Event.published.order(updated_at: :desc)

    builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
      xml.urlset(xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9") do
        # Homepage
        xml.url do
          xml.loc "https://hafapass.netlify.app/"
          xml.changefreq "weekly"
          xml.priority "1.0"
        end

        # Events listing
        xml.url do
          xml.loc "https://hafapass.netlify.app/events"
          xml.changefreq "daily"
          xml.priority "0.9"
        end

        # Individual published events
        @events.each do |event|
          xml.url do
            xml.loc { xml.text "https://hafapass.netlify.app/events/#{event.slug}" }
            xml.lastmod event.updated_at.strftime("%Y-%m-%d")
            xml.changefreq "weekly"
            xml.priority "0.7"
          end
        end
      end
    end

    render xml: builder.to_xml
  end
end
