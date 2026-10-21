# frozen_string_literal: true

require "prawn"

class ReceiptPdfGenerator
  def initialize(order)
    @order = order
  end

  def generate
    I18n.with_locale(AppLocale.i18n_locale(@order.locale)) do
      lines = receipt_lines
      Prawn::Document.new(page_size: "A4", margin: 48) do |pdf|
        title = I18n.t("emails.receipt.title")
        unsupported = PdfFonts.configure(pdf, texts: lines + [title], locale: @order.locale, strict: false)
        pdf.font_size 10
        pdf.text PdfFonts.replace_unsupported(title, unsupported), size: 18, style: :bold
        pdf.move_down 12
        lines.each_with_index do |line, index|
          pdf.text PdfFonts.replace_unsupported(line, unsupported)
          pdf.move_down(index == 3 || index == lines.length - 1 ? 12 : 5)
        end
      end.render
    end
  end

  private

  def receipt_lines
    seller = SellerIdentity.for_event(@order.event)
    time_zone = @order.event.timezone.presence || "Pacific/Guam"
    purchased_at = (@order.completed_at || @order.created_at).in_time_zone(time_zone)
    event_at = @order.event.starts_at&.in_time_zone(time_zone)
    lines = [
      I18n.t("emails.receipt.order_number", reference: @order.reference),
      I18n.t("emails.receipt.order_date", date: purchased_at.strftime("%B %-d, %Y %-I:%M %p %Z")),
      I18n.t("emails.receipt.event", title: @order.event.title,
        date: event_at&.strftime("%B %-d, %Y %-I:%M %p %Z") || ""),
      I18n.t("emails.receipt.seller_line", seller: seller.seller_name, service: seller.ticketing_service),
      I18n.t("emails.order_confirmation.seller_disclosure", seller: seller.seller_name,
        service: seller.ticketing_service, operator: seller.operator_name)
    ]
    lines.unshift(I18n.t("emails.receipt.test_notice")) if %w[test simulated].include?(@order.payment_environment)
    @order.order_items.order(:id).each do |item|
      lines << I18n.t("emails.receipt.line_item", name: item.name, quantity: item.quantity,
        unit: money(item.unit_price_cents), amount: money(item.subtotal_cents))
    end
    lines << I18n.t("emails.receipt.subtotal", amount: money(@order.subtotal_cents))
    lines << I18n.t("emails.receipt.service_fee", amount: money(@order.service_fee_cents))
    lines << I18n.t("emails.receipt.discount", amount: money(@order.discount_cents))
    lines << if @order.total_cents.zero?
      I18n.t("emails.receipt.complimentary")
    elsif %w[test simulated].include?(@order.payment_environment)
      I18n.t("emails.receipt.test_total", amount: money(@order.total_cents))
    else
      I18n.t("emails.receipt.total_paid", amount: money(@order.total_cents))
    end
    lines << payment_method_line
    refunds = @order.refunds.order(created_at: :asc, id: :asc)
    if refunds.empty?
      lines << I18n.t("emails.receipt.no_refunds")
    else
      refunds.each do |refund|
        lines << I18n.t("emails.receipt.refund", amount: money(refund.amount_cents),
          status: I18n.t("emails.receipt.refund_status.#{refund.status}"),
          date: refund.created_at.in_time_zone(time_zone).strftime("%B %-d, %Y %-I:%M %p %Z"))
      end
    end
    lines
  end

  def payment_method_line
    payment = @order.payments.where(status: [:succeeded, :partially_refunded, :refunded]).order(:id).last
    unless payment
      stored_method = @order.payment_method.presence
      method = stored_method ? I18n.t("emails.receipt.payment_type.#{stored_method}",
        default: I18n.t("emails.receipt.payment_type.other")) :
        I18n.t("emails.receipt.not_recorded")
      return I18n.t("emails.receipt.payment_method", method: method)
    end

    payload = payment.provider_payload.to_h
    brand = payload["cardType"] || payload["card_brand"]
    last4 = payload["last4"] || payload["card_last4"]
    method = if brand.to_s.match?(/\A[a-zA-Z0-9 -]{1,24}\z/) && last4.to_s.match?(/\A\d{4}\z/)
      I18n.t("emails.receipt.card", brand: brand, last4: last4)
    else
      I18n.t("emails.receipt.payment_type.#{payment.provider}",
        default: I18n.t("emails.receipt.payment_type.other"))
    end
    I18n.t("emails.receipt.payment_method", method: method)
  end

  def money(cents)
    UsdMoney.format_cents(cents)
  end
end
