# frozen_string_literal: true

class Api::V1::Organizer::TaxInformationsController < Api::V1::Organizer::BaseController
  before_action -> { authorize_organization!(:manage_payout_settings) }
  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def show
    record = current_organization.organizer_tax_information
    render json: { tax_information: record&.safe_json, edit_locked: edit_locked?,
      certification: OrganizerTaxInformation::CERTIFICATION }
  end

  def update
    record = OrganizerTaxInformationUpdater.call(organization: current_organization,
      attributes: params.require(:tax_information).permit(:legal_name, :business_name, :tax_classification,
        :tin_type, :tin, :mailing_address, :exempt_payee_code, :signer_name, :certified),
      actor: current_user, request: request)
    render json: { tax_information: record.safe_json, edit_locked: false,
      certification: OrganizerTaxInformation::CERTIFICATION }
  rescue OrganizerTaxInformationUpdater::TaxError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def edit_locked?
    current_organization.payouts.where(provider: "check", status: [:pending, :processing]).exists?
  end
end
