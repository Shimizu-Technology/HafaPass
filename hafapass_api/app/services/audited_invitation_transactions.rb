# frozen_string_literal: true

module AuditedInvitationTransactions
  def accept!(**arguments)
    AuditContext.set(actor: arguments[:user]) do
      ActiveRecord::Base.transaction { super }
    end
  end
end
