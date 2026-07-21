class SitemapsController < ApplicationController
  skip_before_action :authenticate_user!

  def show
    @events = Event.published.where(live_money_proof_candidate: false)
      .where("COALESCE(events.ends_at, events.starts_at) > ?", Time.current).order(updated_at: :desc)
    @collections = MarketplaceCollection.currently_visible.with_discoverable_events
    @venues = Venue.published.joins(:events).merge(Event.discoverable).distinct
    @organizers = Organization.status_active.joins(:events).merge(Event.discoverable).distinct
    base_url = PublicSiteUrl.base

    builder = Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
      xml.urlset(xmlns: "http://www.sitemaps.org/schemas/sitemap/0.9") do
        # Homepage
        xml.url do
          xml.loc "#{base_url}/"
          xml.changefreq "weekly"
          xml.priority "1.0"
        end

        # Events listing
        xml.url do
          xml.loc "#{base_url}/events"
          xml.changefreq "daily"
          xml.priority "0.9"
        end

        # Individual published events
        @events.each do |event|
          xml.url do
            xml.loc { xml.text "#{base_url}/events/#{event.slug}" }
            xml.lastmod event.updated_at.strftime("%Y-%m-%d")
            xml.changefreq "weekly"
            xml.priority "0.7"
          end
        end


        @collections.each do |collection|
          sitemap_url(xml, "#{base_url}/collections/#{collection.slug}", collection.updated_at, "daily", "0.7")
        end
        @venues.each do |venue|
          sitemap_url(xml, "#{base_url}/venues/#{venue.slug}", venue.updated_at, "weekly", "0.6")
        end
        @organizers.each do |organization|
          sitemap_url(xml, "#{base_url}/organizers/#{organization.slug}", organization.updated_at, "weekly", "0.6")
        end
      end
    end

    render xml: builder.to_xml
  end

  private

  def sitemap_url(xml, location, updated_at, frequency, priority)
    xml.url do
      xml.loc { xml.text location }
      xml.lastmod updated_at.strftime("%Y-%m-%d")
      xml.changefreq frequency
      xml.priority priority
    end
  end
end
