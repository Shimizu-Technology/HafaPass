# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :credential, :qr_code, :passw, :email, :phone, :secret, :token, :authorization, :_key, :crypt, :salt,
  :certificate, :code, :verification_code, :otp, :ssn, :tin, :tax_information,
  :card_number, :account_number, :bank_account_number, :note, :cvv, :cvc, :file, :upload, :"X-Preview-Token", :"HTTP_X_PREVIEW_TOKEN"
]
