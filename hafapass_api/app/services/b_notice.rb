# frozen_string_literal: true

class BNotice
  class NoticeError < StandardError; end

  def self.business_days_after(date, days)
    current = date.to_date
    days.times do
      current += 1
      current += 1 while current.saturday? || current.sunday? || federal_holidays(current.year).include?(current)
    end
    current
  end

  def self.federal_holidays(year)
    fixed = [[1, 1], [6, 19], [7, 4], [11, 11], [12, 25]].flat_map do |month, day|
      date = Date.new(year, month, day)
      [date.saturday? ? date - 1 : date.sunday? ? date + 1 : date]
    end
    # Include the observed New Year's Day of the following year when it falls
    # on December 31 of this year.
    fixed << Date.new(year, 12, 31) if Date.new(year + 1, 1, 1).saturday?
    nth = ->(month, weekday, occurrence) { (Date.new(year, month, 1)..Date.new(year, month, -1)).select { |day| day.wday == weekday }[occurrence - 1] }
    fixed.concat([nth.call(1, 1, 3), nth.call(2, 1, 3), nth.call(9, 1, 1), nth.call(10, 1, 2),
      nth.call(11, 4, 4), (Date.new(year, 5, 1)..Date.new(year, 5, -1)).select(&:monday?).last])
    fixed.to_set
  end
  private_class_method :federal_holidays

  def self.pdf(tax:, stage:)
    raise NoticeError, "Choose first or second notice" unless %w[first second].include?(stage)

    Prawn::Document.new(page_size: "LETTER", margin: 54) do |pdf|
      pdf.text "HåfaPass - #{stage.capitalize} B-notice", size: 18, style: :bold
      pdf.move_down 20
      pdf.text Date.current.to_s
      pdf.text tax.legal_name
      pdf.text tax.mailing_address
      pdf.move_down 24
      pdf.text "Account: organization #{tax.organization_id}; TIN ending #{tax.tin_last_four}"
      pdf.move_down 16
      pdf.text "Our records show that the name and taxpayer identification number for this account require correction. " \
        "Please respond within 30 business days of the notice date. Contact HåfaPass through your organizer dashboard; do not email a TIN."
      pdf.move_down 14
      if stage == "first"
        pdf.text "First notice: provide a new completed and signed Form W-9 (or acceptable substitute) with the correct name and TIN."
      else
        pdf.text "Second notice: provide the verification required by the IRS, such as a Social Security card or IRS Letter 147C. " \
          "A new W-9 alone may not resolve a second notice."
      end
      pdf.move_down 20
      pdf.text "This is a preparation template. Operations must confirm the triggering IRS notice and mailing requirements with the CPA."
    end.render
  end
end
