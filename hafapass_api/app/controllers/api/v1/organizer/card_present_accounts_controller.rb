# frozen_string_literal: true

class Api::V1::Organizer::CardPresentAccountsController < Api::V1::Organizer::BaseController
  def show
    return unless authorize_organization!(:view_events)

    account = current_organization.card_present_account
    payload = if account
      {
        provider: account.provider,
        status: account.status,
        payment_ready: account.payment_ready? && CardPresentGateway.configured_for?(account),
        connection_mode: account.connection_mode,
        last_seen_at: account.last_seen_at
      }
    else
      { provider: "boh_clover", status: "not_configured", payment_ready: false }
    end
    render json: payload
  end
end
