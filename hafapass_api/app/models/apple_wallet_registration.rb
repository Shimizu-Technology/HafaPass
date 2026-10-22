# frozen_string_literal: true

# A device that asked Apple Wallet to receive updates for one pass serial.
class AppleWalletRegistration < ApplicationRecord
  IDENTIFIER_FORMAT = /\A[A-Za-z0-9._-]{1,128}\z/
  PUSH_TOKEN_FORMAT = /\A[0-9A-Fa-f]{16,200}\z/

  belongs_to :wallet_pass

  validates :device_library_identifier, presence: true, format: { with: IDENTIFIER_FORMAT },
    uniqueness: { scope: :wallet_pass_id }
  validates :push_token, presence: true, format: { with: PUSH_TOKEN_FORMAT }
end
