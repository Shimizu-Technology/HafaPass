# frozen_string_literal: true

Rails.application.config.to_prepare do
  OrganizationTeam.singleton_class.prepend(AuditedTeamTransactions)
  OrganizationInvitation.singleton_class.prepend(AuditedInvitationTransactions)
end
