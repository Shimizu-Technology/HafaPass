# frozen_string_literal: true

class Api::V1::Organizer::ConnectedAccountsController < Api::V1::Organizer::BaseController
  before_action :require_payout_management

  def index
    render json: current_organization.connected_accounts.order(:id).map { |account| account_json(account) }
  end

  def create
    account = ConnectedAccounts::Manager.start!(
      organization: current_organization,
      provider: params[:provider],
      actor: current_user,
      request: request
    )
    render json: account_json(account).merge(next_action: next_action(account)), status: :created
  rescue ConnectedAccounts::Manager::AccountError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def require_payout_management
    authorize_organization!(:manage_payout_settings)
  end

  def next_action(account)
    case account.provider
    when "paypal" then "HafaPass marketplace approval and PayPal seller onboarding are required"
    when "manual" then "Submit banking documents for finance review"
    when "stripe" then "Do not continue until Stripe confirms Guam entity and bank eligibility in writing"
    end
  end

  def account_json(account)
    {
      id: account.id,
      provider: account.provider,
      status: account.status,
      charges_enabled: account.charges_enabled,
      payouts_enabled: account.payouts_enabled,
      details_submitted: account.details_submitted,
      requirements_due: account.requirements_due,
      capabilities: account.capabilities,
      country: account.country,
      currency: account.currency,
      payout_ready: account.payout_ready?,
      last_synced_at: account.last_synced_at
    }
  end
end
