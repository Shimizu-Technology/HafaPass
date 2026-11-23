# frozen_string_literal: true

module Wallet
  # What a saved wallet pass may show for one issued credential version. A pass
  # carries a barcode only while that exact credential admits; anything that
  # permanently replaces or ends the ticket voids it.
  class PassState
    attr_reader :ticket, :scan_credential_version

    def initialize(ticket, scan_credential_version: ticket.scan_credential_version)
      @ticket = ticket
      @scan_credential_version = scan_credential_version
    end

    def current_credential?
      ticket.scan_credential_version == scan_credential_version
    end

    def barcode?
      current_credential? && ticket.admission_allowed?
    end

    def voided?
      !current_credential? || ticket.cancelled? || ticket.transferred? || ticket.inventory_retained? ||
        ticket.order.refunded? || ticket.order.cancelled? || ticket.event.cancelled? || ticket.event.archived?
    end

    def event_ended?(at: Time.current)
      ending = ticket.event.ends_at || ticket.event.starts_at
      ending.present? && ending < at
    end

    def label(key, **options)
      I18n.t("ticket_documents.wallet.#{key}", locale: AppLocale.i18n_locale(ticket.order.locale), **options)
    end

    def status_label
      label(status_key)
    end

    def google_state(at: Time.current)
      return "INACTIVE" if voided?
      return "EXPIRED" if event_ended?(at: at)
      return "COMPLETED" if ticket.checked_in?

      barcode? ? "ACTIVE" : "INACTIVE"
    end

    private

    def status_key
      return :replaced unless current_credential?
      return :cancelled if ticket.cancelled? || ticket.order.cancelled?
      return :transferred if ticket.transferred?
      return :refunded if ticket.order.refunded? || ticket.inventory_retained?
      return :event_cancelled if ticket.event.cancelled?
      return :unavailable if ticket.event.archived?
      return :checked_in if ticket.checked_in?
      return :payment_dispute if ticket.order.ticket_access_blocked?
      return :refund_pending if ticket.refund_pending?
      return :event_postponed if ticket.event.postponed?

      barcode? ? :valid : :invalid
    end
  end
end
