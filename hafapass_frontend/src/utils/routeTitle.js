import { isWorkspacePath } from './workspacePath'

// Account, order and ticket pages carry personal links; they never belong in
// search results, even before their page-specific title loads.
const PRIVATE_BUYER_PATH = /^\/(checkout|orders|tickets|my-tickets|saved|unsubscribe|privacy|account|ticket-transfers|organization-invitations|platform-invitations|sign-in|sign-up)(?:\/|$)/

const EVENT_TOOL_TITLES = {
  edit: 'editEvent', analytics: 'eventAnalytics', 'promo-codes': 'promoCodes', 'guest-list': 'guestList',
  refunds: 'refunds', attendees: 'attendees', 'box-office': 'boxOffice', waitlist: 'waitlist',
  'sales-tools': 'salesTools', seating: 'seating', team: 'eventTeam',
}

const ADMIN_TITLES = {
  events: 'adminEvents', users: 'adminUsers', organizations: 'adminOrganizations', orders: 'adminOrders',
  marketplace: 'adminMarketplace', 'provider-readiness': 'adminProviderReadiness', settings: 'adminSettings',
  privacy: 'adminPrivacy', 'tax-reports': 'adminTaxReports', 'tax-controls': 'adminTaxControls',
  payouts: 'adminPayouts', disputes: 'adminDisputes', refund_reconciliation: 'adminRefundReconciliation',
  'audit-log': 'adminAuditLog', operations: 'adminOperations',
}

const BUYER_TITLES = {
  checkout: 'checkout', orders: 'order', tickets: 'ticket', 'my-tickets': 'myTickets', saved: 'saved',
  unsubscribe: 'emailPreferences', privacy: 'privacyChoices', account: 'privacyChoices',
  'ticket-transfers': 'ticketTransfer', 'organization-invitations': 'invitation',
  'platform-invitations': 'invitation', 'sign-in': 'signIn', 'sign-up': 'signUp',
}

function workspaceTitle(segments) {
  const [area, second, third, fourth] = segments
  if (area === 'support') return 'support'
  if (area === 'admin') {
    if (second === 'organizations' && third) return 'adminOrganization'
    return second ? ADMIN_TITLES[second] || 'admin' : 'admin'
  }
  if (second === 'events') {
    if (third === 'new') return 'createEvent'
    if (third) return fourth ? EVENT_TOOL_TITLES[fourth] || 'eventOverview' : 'eventOverview'
  }
  if (second === 'scanner') return 'scanner'
  if (second === 'finances') return 'finances'
  if (second === 'settings') return third === 'activity' ? 'activity' : 'settings'
  return 'dashboard'
}

// The default document head for routes whose pages may never set one
// (workspace tools) or must stay out of indexes (buyer account links).
// Returns null for public pages, which set their own title and canonical URL.
export function routeTitleKey(pathname) {
  const segments = pathname.split('/').filter(Boolean)
  if (isWorkspacePath(pathname)) return `pageTitles.${workspaceTitle(segments)}`
  if (PRIVATE_BUYER_PATH.test(pathname)) return `pageTitles.${BUYER_TITLES[segments[0]]}`
  return null
}
