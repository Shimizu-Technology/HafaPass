# frozen_string_literal: true

require "csv"

# Shared CSV helpers for organizer exports: formula-injection protection and a
# row-by-row streamed response so large exports never sit in memory at once.
module SpreadsheetExport
  extend ActiveSupport::Concern

  # A number the export itself formatted (e.g. "-12.34"). It is written as-is
  # so spreadsheets read it as a number; only free text gets the guard below.
  class Amount < String; end

  INCOMPLETE_MARKER = "EXPORT INCOMPLETE: an error stopped this file early. Download it again or contact support."

  def self.safe_value(value)
    return value if !value.is_a?(String) || value.is_a?(Amount)

    value.match?(/\A[[:space:]\u0000-\u001f]*[=+@\-＝＋＠－]/) || value.match?(/\A[\t\r\n]/) ? "\t#{value}" : value
  end

  private

  def spreadsheet_safe(value)
    SpreadsheetExport.safe_value(value)
  end

  # Streams header + rows. `rows` is any enumerable yielding arrays; each free-
  # text value is made spreadsheet-safe. Cache headers keep Rack::ETag from
  # buffering. Headers are already sent when a row fails, so the file ends
  # with a marker row and the error is logged and reported.
  def stream_csv(filename:, header:, rows:, bom: false)
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(
      disposition: "attachment", filename: filename
    )
    response.headers["Cache-Control"] = "no-store, no-cache"
    response.headers["Last-Modified"] = Time.current.httpdate
    response.headers.delete("Content-Length")
    self.status = :ok
    self.response_body = Enumerator.new do |output|
      output << "\uFEFF" if bom
      output << CSV.generate_line(header, force_quotes: true)
      begin
        rows.each { |row| output << CSV.generate_line(row.map { |value| spreadsheet_safe(value) }, force_quotes: true) }
      rescue StandardError => e
        Rails.logger.error("[csv_export] #{filename} stopped early: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        output << CSV.generate_line([INCOMPLETE_MARKER], force_quotes: true)
      end
    end
  end
end
