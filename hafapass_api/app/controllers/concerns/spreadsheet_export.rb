# frozen_string_literal: true

require "csv"

# Shared CSV helpers for organizer exports: formula-injection protection and a
# row-by-row streamed response so large exports never sit in memory at once.
module SpreadsheetExport
  extend ActiveSupport::Concern

  private

  def spreadsheet_safe(value)
    return value unless value.is_a?(String)

    # OWASP's Excel-resistant mitigation is a tab inside a quoted field. An
    # apostrophe alone may be stripped when Excel saves/reopens a CSV. This
    # export is for spreadsheet viewing; the protective tab is exported data.
    value.match?(/\A[[:space:]\u0000-\u001f]*[=+@\-＝＋＠－]/) || value.match?(/\A[\t\r\n]/) ? "\t#{value}" : value
  end

  # Streams header + rows. `rows` is any enumerable yielding arrays; each value
  # is made spreadsheet-safe. Cache headers keep Rack::ETag from buffering.
  def stream_csv(filename:, header:, rows:)
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename: filename
    )
    response.headers["Cache-Control"] = "no-store, no-cache"
    response.headers["Last-Modified"] = Time.current.httpdate
    response.headers.delete("Content-Length")
    self.status = :ok
    self.response_body = Enumerator.new do |output|
      output << CSV.generate_line(header, force_quotes: true)
      rows.each { |row| output << CSV.generate_line(row.map { |value| spreadsheet_safe(value) }, force_quotes: true) }
    end
  end
end
