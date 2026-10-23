const organizerSteps = {
  organizer_verified: ['Waiting for HåfaPass to verify your organization before tickets go on sale', null],
  policy_accepted: ['Accept the organizer agreement', '/dashboard'],
  title: ['Add the event title', '#title'],
  description: ['Describe your event', '#description'],
  venue: ['Add the venue name, address, and city', '#venue_name'],
  schedule: ['Set a future start and an end time', '#starts_at'],
  timezone: ['Confirm the event time zone', '#starts_at'],
  tickets: ['Add at least one ticket type', '#ticket-types'],
  capacity: ['Set capacity and ticket quantities that fit', '#max_capacity'],
  sales_window: ['Set valid ticket sales dates', '#ticket-types'],
  payout: ['Complete Tax information and How you get paid in Settings, then wait for finance approval.', '/dashboard/settings'],
}

const completeLabels = {
  payout: 'Paid-ticket setup approved, or not needed for free tickets',
  organizer_verified: 'HåfaPass verified your organization',
}

// Steps an organizer can act on. Codes the app does not know (retired
// release reviews, internal checks) are dropped rather than shown as jargon.
// `organizer_verified` has no link; the page shows the verification request
// action instead (`requestVerification: true`).
export function organizerChecklist(checklist) {
  return checklist.filter(item => organizerSteps[item.code]).map(item => ({
    ...item,
    label: item.complete && completeLabels[item.code] ? completeLabels[item.code] : organizerSteps[item.code][0],
    href: organizerSteps[item.code][1],
    requestVerification: item.code === 'organizer_verified' && !item.complete,
  }))
}

// Whether an item holds back publishing. The server marks items that only
// hold back ticket sales (for example organizer verification in production)
// with `required_to_publish: false`; older servers omit it and every item blocks.
export const blocksPublishing = item => item.required_to_publish !== false
