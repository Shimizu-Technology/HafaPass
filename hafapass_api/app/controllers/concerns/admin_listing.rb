# frozen_string_literal: true

# Offset pagination for read-only admin lists. Meta matches the frontend's
# OperationalPagination (page, total_pages, total_count).
module AdminListing
  extend ActiveSupport::Concern

  MAX_PER_PAGE = 100

  private

  def admin_page(scope, default_per_page: 25)
    per_page = params[:per_page].to_i
    per_page = default_per_page unless per_page.between?(1, MAX_PER_PAGE)
    page = [params[:page].to_i, 1].max
    total = scope.count
    records = scope.offset((page - 1) * per_page).limit(per_page).to_a
    [records, { page: page, per_page: per_page, total_count: total, total_pages: (total.to_f / per_page).ceil }]
  end

  def search_term
    params[:q].to_s.strip.first(200).presence
  end

  def like_pattern(term)
    "%#{ActiveRecord::Base.sanitize_sql_like(term)}%"
  end

  def user_summary(user)
    return nil unless user

    { id: user.id, email: user.email, name: [user.first_name, user.last_name].compact_blank.join(" ").presence }
  end
end
