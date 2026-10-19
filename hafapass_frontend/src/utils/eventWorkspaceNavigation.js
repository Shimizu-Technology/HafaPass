import { LayoutDashboard, FilePenLine, Ticket, Users, ScanLine, Megaphone, UserRoundCog, WalletCards } from 'lucide-react'

// The single list of event tools. The workspace sidebar and the event
// overview's quick links both read it, so a tool cannot appear in one only.
export function navigationFor(event, capabilities) {
  const p = event?.permissions || {}
  const has = key => p[key] === true
  const base = `/dashboard/events/${event.id}`
  return [
    { label: 'Overview', icon: LayoutDashboard, links: [{ label: 'Overview', to: base, allowed: has('view_events') }] },
    { label: 'Event details', icon: FilePenLine, links: [{ label: 'Edit event', to: `${base}/edit`, allowed: has('edit_event_content') }] },
    { label: 'Tickets & seating', icon: Ticket, links: [
      { label: 'Ticket types', to: `${base}/edit#ticket-types`, allowed: has('manage_inventory') && has('edit_event_content') },
      { label: 'Assigned seating', to: `${base}/seating`, allowed: has('manage_inventory') && (capabilities.assigned_seating === true || event.assigned_seating === true) },
    ] },
    { label: 'Attendees', icon: Users, links: [
      { label: 'Attendee list', to: `${base}/attendees`, allowed: has('view_attendees') },
      { label: 'Guest list', to: `${base}/guest-list`, allowed: has('manage_attendees') },
      { label: 'Waitlist', to: `${base}/waitlist`, allowed: has('manage_attendees') },
    ] },
    { label: 'Event day', icon: ScanLine, links: [
      { label: 'Scan tickets', to: `/dashboard/scanner?event=${event.id}`, allowed: has('scan') },
      { label: 'Box office', to: `${base}/box-office`, allowed: has('box_office') },
    ] },
    { label: 'Sales & messages', icon: Megaphone, links: [
      { label: 'Promo codes', to: `${base}/promo-codes`, allowed: has('manage_marketing') },
      { label: 'Sales tools & messages', to: `${base}/sales-tools`, allowed: has('manage_marketing') && capabilities.advanced_sales_tools === true },
    ] },
    { label: 'Team', icon: UserRoundCog, links: [{ label: 'Event team', to: `${base}/team`, allowed: has('manage_staff') }] },
    { label: 'Finances', icon: WalletCards, links: [
      { label: 'Sales & finances', to: `${base}/analytics`, allowed: has('view_finance') },
      { label: 'Refunds', to: `${base}/refunds`, allowed: has('refund') && has('view_finance') },
    ] },
  ].map(group => ({ ...group, links: group.links.filter(link => link.allowed === true) })).filter(group => group.links.length)
}

// Every permitted tool except the overview itself, in sidebar order.
export const eventToolLinks = (event, capabilities) => navigationFor(event, capabilities)
  .filter(group => group.label !== 'Overview')
  .flatMap(group => group.links)
