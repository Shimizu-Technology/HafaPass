# frozen_string_literal: true

module Paginatable
  extend ActiveSupport::Concern

  included do
    include Pagy::Backend
  end

  private

  # Paginate a collection and set response headers
  # Returns [pagy, paginated_records]
  def paginate(collection, items: nil)
    items ||= params[:per_page]&.to_i
    pagy, records = pagy(collection, limit: items)
    set_pagination_headers(pagy)
    [pagy, records]
  end

  # Set pagination metadata in response headers
  def set_pagination_headers(pagy)
    response.set_header("X-Total-Count", pagy.count.to_s)
    response.set_header("X-Total-Pages", pagy.pages.to_s)
    response.set_header("X-Page", pagy.page.to_s)
    response.set_header("X-Per-Page", pagy.limit.to_s)
  end

  # Build pagination metadata for JSON response
  def pagination_meta(pagy)
    {
      current_page: pagy.page,
      total_pages: pagy.pages,
      total_count: pagy.count,
      per_page: pagy.limit,
      next_page: pagy.next,
      prev_page: pagy.prev
    }
  end
end
