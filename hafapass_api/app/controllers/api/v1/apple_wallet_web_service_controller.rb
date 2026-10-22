# frozen_string_literal: true

# Apple Wallet's PassKit web service:
# https://developer.apple.com/documentation/walletpasses/adding-a-web-service-to-update-passes
# Devices register for update pushes, ask which serials changed, then download
# the latest pass. Every pass-specific call must present the pass's
# authenticationToken as "Authorization: ApplePass <token>".
class Api::V1::AppleWalletWebServiceController < ApplicationController
  MAX_DEVICES_PER_PASS = 20
  MAX_SERIALS_PER_DEVICE = 50
  MAX_LOG_ENTRIES = 20

  skip_before_action :authenticate_user!
  before_action :require_apple_wallet
  before_action :require_pass_type, except: :log
  before_action :validate_device_identifier, only: %i[register unregister serial_numbers]
  before_action :authenticate_pass!, only: %i[register unregister latest_pass]

  def register
    push_token = params[:pushToken].to_s
    return head :bad_request unless push_token.match?(AppleWalletRegistration::PUSH_TOKEN_FORMAT)

    created = false
    @wallet_pass.with_lock do
      registration = @wallet_pass.apple_wallet_registrations.find_or_initialize_by(device_library_identifier: device_identifier)
      created = registration.new_record?
      registration.update!(push_token: push_token)
      # Keep the newest devices if one pass is registered on unusually many.
      stale = @wallet_pass.apple_wallet_registrations.order(updated_at: :desc).offset(MAX_DEVICES_PER_PASS)
      stale.destroy_all
    end
    head(created ? :created : :ok)
  rescue ActiveRecord::RecordNotUnique
    head :ok
  end

  def unregister
    @wallet_pass.apple_wallet_registrations.where(device_library_identifier: device_identifier).delete_all
    head :ok
  end

  def serial_numbers
    since = updated_since
    return head :bad_request if since == :invalid

    # Newest changes first, so a device with many passes still learns of them.
    passes = WalletPass.apple.joins(:apple_wallet_registrations)
      .where(apple_wallet_registrations: { device_library_identifier: device_identifier })
      .order(Arel.sql("wallet_passes.content_updated_at DESC NULLS LAST, wallet_passes.id DESC"))
      .limit(MAX_SERIALS_PER_DEVICE).to_a
    # On a follow-up poll, a change that never reached the sync job still
    # shows up. The first poll lists everything, so it needs no refresh.
    passes.each { |wallet_pass| Wallet::PassSync.refresh_apple_content!(wallet_pass) } if since

    updated = passes.select { |wallet_pass| wallet_pass.content_updated_at && (since.nil? || wallet_pass.content_updated_at > since) }
    return head :no_content if updated.empty?

    render json: { serialNumbers: updated.map(&:serial_number), lastUpdated: updated.map(&:update_tag).max_by(&:to_i) }
  end

  def latest_pass
    Wallet::PassSync.refresh_apple_content!(@wallet_pass)
    modified_at = @wallet_pass.content_updated_at || @wallet_pass.created_at
    # HTTP dates carry whole seconds. Each change to one pass advances its
    # time by at least a second (WalletPass#record_content!), so comparing
    # whole seconds never hides a newer change.
    since = http_date(request.headers["If-Modified-Since"])
    return head :not_modified if since && since >= modified_at.change(usec: 0)

    response.headers["Last-Modified"] = modified_at.httpdate
    send_data Wallet::ApplePassGenerator.latest(@wallet_pass, authentication_token: presented_token),
      type: "application/vnd.apple.pkpass", disposition: "attachment", filename: "#{@wallet_pass.serial_number}.pkpass"
  rescue Wallet::ApplePassGenerator::ConfigurationError
    head :service_unavailable
  end

  # Device-side PassKit errors. Kept short and never echoed back.
  def log
    Array(params[:logs]).first(MAX_LOG_ENTRIES).each do |entry|
      Rails.logger.warn("[AppleWallet] device log: #{entry.to_s.gsub(/[[:cntrl:]]/, ' ').first(500)}")
    end
    head :ok
  end

  private

  def require_apple_wallet
    head :service_unavailable unless Wallet::ApplePassGenerator.enabled?
  end

  def require_pass_type
    expected = Wallet::ApplePassGenerator.pass_type_identifier
    head :not_found unless expected.present? && ActiveSupport::SecurityUtils.secure_compare(params[:pass_type_identifier].to_s, expected)
  end

  def validate_device_identifier
    head :bad_request unless device_identifier.match?(AppleWalletRegistration::IDENTIFIER_FORMAT)
  end

  def authenticate_pass!
    @wallet_pass = WalletPass.apple.includes(ticket: [:order, :event, :ticket_type]).find_by(serial_number: params[:serial_number].to_s)
    head :unauthorized unless @wallet_pass&.authenticates?(presented_token)
  end

  def presented_token
    scheme, token = request.authorization.to_s.split(" ", 2)
    scheme == "ApplePass" ? token.to_s.strip : nil
  end

  def device_identifier
    params[:device_library_identifier].to_s
  end

  def http_date(value)
    Time.httpdate(value) if value.present?
  rescue ArgumentError
    nil
  end

  def updated_since
    value = params[:passesUpdatedSince].presence
    return if value.nil?
    return :invalid unless value.match?(/\A\d{1,19}\z/)

    WalletPass.time_for_tag(value)
  end
end
