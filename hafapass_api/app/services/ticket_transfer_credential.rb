# frozen_string_literal: true

class TicketTransferCredential
  NAMESPACE = "ticket_transfer_acceptance"

  def self.issue(transfer)
    SignedCredential.issue(
      namespace: NAMESPACE,
      payload: { transfer_id: transfer.id, version: transfer.token_version },
      expires_at: transfer.expires_at
    )
  end

  def self.find(token)
    payload = SignedCredential.verify(namespace: NAMESPACE, token: token)
    return unless payload

    transfer = TicketTransfer.find_by(id: payload["transfer_id"])
    version = payload["version"]
    return unless transfer && ActiveSupport::SecurityUtils.secure_compare(transfer.token_version.to_s, version.to_s)

    transfer
  end
end
