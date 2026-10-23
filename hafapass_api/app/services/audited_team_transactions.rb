# frozen_string_literal: true

# Existing team services deliberately enqueue email after their row locks.
# Keep the audit and those locks inside one outer transaction without changing
# their authorization/lock ordering (also used by the permissions workstream).
module AuditedTeamTransactions
  %i[invite! resend! revoke! change_role! transfer_ownership!].each do |operation|
    define_method(operation) do |**arguments|
      AuditContext.set(actor: arguments[:actor] || AuditContext.actor) do
        ActiveRecord::Base.transaction { super(**arguments) }
      end
    end
  end
end
