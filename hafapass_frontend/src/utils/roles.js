import { resolvePublicWebUrl } from './site'
import roleMatrix from '../generated/roleMatrix.json'

// Labels come from OrganizationRoles through the checked generated artifact.
// These descriptions are sentence versions of the API's email copy.
const ORGANIZATION_ROLE_DESCRIPTIONS = {
  owner: 'Manages the team, payouts and all events.',
  manager: 'Runs events day to day and sees sales. Can’t cancel events or move money.',
  finance: 'Sales reports, refunds and payouts, including buyer contact details in refunds and finance exports.',
  marketer: 'Event pages, promo codes and messages.',
  box_office: 'Door sales and fixes for assigned events, plus scanning.',
  scanner: 'Scans tickets at assigned events only.',
}
export const ORGANIZATION_ROLES = Object.fromEntries(roleMatrix.roles.map(({ key, label }) => [key, {
  label, description: ORGANIZATION_ROLE_DESCRIPTIONS[key],
}]))

export const PLATFORM_ROLES = {
  admin: { label: 'Admin', description: 'Runs HåfaPass.' },
  support: { label: 'Support', description: 'Helps buyers with orders and tickets, no money or settings.' },
}

// Roles an owner can hand out; Owner moves only through Transfer ownership.
export const TEAM_ROLES = ['manager', 'finance', 'marketer', 'box_office', 'scanner']
// Roles that can be invited straight onto one event.
export const EVENT_INVITE_ROLES = ['box_office', 'scanner']
// Event assignments for people already on the team.
export const EVENT_ASSIGNMENT_DESCRIPTION = roleMatrix.notes.assignments
export const EVENT_ASSIGNMENT_ROLES = ['manager', 'box_office', 'scanner']

const humanize = value => value ? value.replaceAll('_', ' ').replace(/^\w/, character => character.toUpperCase()) : ''

export const roleLabel = role => ORGANIZATION_ROLES[role]?.label || PLATFORM_ROLES[role]?.label || humanize(role)
export const roleDescription = role => ORGANIZATION_ROLES[role]?.description || PLATFORM_ROLES[role]?.description || ''

export const INVITATION_STATUS = {
  pending: { label: 'Invite pending', tone: 'warning' },
  accepted: { label: 'Active', tone: 'success' },
  expired: { label: 'Invite expired', tone: 'neutral' },
  access_ended: { label: 'Access ended', tone: 'neutral' },
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

export const OFFLINE_SCANNER_ACCESS_NOTE = roleMatrix.notes.offline

export function accessExpiryLabel(value, now = Date.now()) {
  if (!value) return null
  const date = new Date(value)
  const formatted = date.toLocaleString('en-US', { timeZone: 'Pacific/Guam', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })
  return `Access ${date.getTime() <= now ? 'ended' : 'until'} ${formatted} Guam time`
}

export const effectiveAssignmentStatus = (assignment, now = Date.now()) => assignment.status === 'revoked' ? 'Removed'
  : assignment.expires_at && Date.parse(assignment.expires_at) <= now ? 'Access ended' : 'Active'
