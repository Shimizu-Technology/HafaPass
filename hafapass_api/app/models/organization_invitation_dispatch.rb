# frozen_string_literal: true

# Durable quota reservations: shared by workers, never dependent on an IP or
# process-local cache. Failed invitations roll back their reservation.
class OrganizationInvitationDispatch < ApplicationRecord
  belongs_to :organization
  belongs_to :actor_user, class_name: "User"
end
