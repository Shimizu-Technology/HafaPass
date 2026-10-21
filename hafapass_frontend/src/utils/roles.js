import { resolvePublicWebUrl } from './site'

// One plain line per role, shown wherever someone chooses a role. The API
// keeps the same copy in app/services/organization_roles.rb for emails.
export const ORGANIZATION_ROLES = {
  owner: { label: 'Owner', description: 'Manages the team, payouts and all events.' },
  manager: { label: 'Manager', description: 'Runs events day to day, sees sales, can’t move money.' },
  finance: { label: 'Finance', description: 'Sales reports, refunds and payouts.' },
  marketer: { label: 'Marketer', description: 'Event pages, promo codes and messages.' },
  box_office: { label: 'Box office', description: 'Door sales and fixes for assigned events, plus scanning.' },
  scanner: { label: 'Door scanner', description: 'Scans tickets at assigned events only.' },
}

export const PLATFORM_ROLES = {
  admin: { label: 'Admin', description: 'Runs HåfaPass.' },
  support: { label: 'Support', description: 'Helps buyers with orders and tickets, no money or settings.' },
}

// Roles an owner can hand out; Owner moves only through Transfer ownership.
export const TEAM_ROLES = ['manager', 'finance', 'marketer', 'box_office', 'scanner']
// Roles that can be invited straight onto one event.
export const EVENT_INVITE_ROLES = ['box_office', 'scanner']
// Event assignments for people already on the team.
export const EVENT_ASSIGNMENT_ROLES = ['manager', 'box_office', 'scanner']

const humanize = value => value ? value.replaceAll('_', ' ').replace(/^\w/, character => character.toUpperCase()) : ''

export const roleLabel = role => ORGANIZATION_ROLES[role]?.label || PLATFORM_ROLES[role]?.label || humanize(role)
export const roleDescription = role => ORGANIZATION_ROLES[role]?.description || PLATFORM_ROLES[role]?.description || ''

export const INVITATION_STATUS = {
  pending: { label: 'Invite pending', tone: 'warning' },
  accepted: { label: 'Active', tone: 'success' },
  expired: { label: 'Invite expired', tone: 'neutral' },
  revoked: { label: 'Removed', tone: 'neutral' },
}

// What happened to the invitation email, in words an organizer can act on.
export function emailDeliveryLabel(delivery) {
  if (!delivery) return 'Email not sent yet — copy the link to share it yourself.'
  if (delivery.provider === 'simulated') return 'Test mode: no real email was sent. Copy the link to share it.'
  if (['sent', 'delivered'].includes(delivery.status)) return 'Invitation emailed.'
  if (['queued', 'delayed'].includes(delivery.status)) return 'Sending the invitation email…'
  return 'The email could not be delivered. Copy the link and share it another way.'
}

// Prefer the URL the API built (the same one the email contains); otherwise
// build it from the configured public site, never the current tab's origin.
// Returns null without a token, so no one is handed a link that can't work.
export const invitationUrl = data => data?.invitation_url
  || (data?.invitation_token ? `${resolvePublicWebUrl()}/organization-invitations/accept?token=${encodeURIComponent(data.invitation_token)}` : null)
