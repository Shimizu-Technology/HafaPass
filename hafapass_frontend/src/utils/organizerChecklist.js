const organizerSteps = {
  organizer_verified: ['Verify your organizer profile', '/dashboard'],
  policy_accepted: ['Accept the organizer agreement', '/dashboard'],
  title: ['Add the event title', '#title'],
  description: ['Describe your event', '#description'],
  venue: ['Add the venue name, address, and city', '#venue_name'],
  schedule: ['Set a future start and an end time', '#starts_at'],
  timezone: ['Confirm the event time zone', '#starts_at'],
  tickets: ['Add at least one ticket type', '#ticket-types'],
  capacity: ['Set capacity and ticket quantities that fit', '#max_capacity'],
  sales_window: ['Set valid ticket sales dates', '#ticket-types'],
  payout: ['Connect an approved account for paid sales', '/dashboard/settings'],
}

export function organizerChecklist(checklist) {
  const steps = checklist.filter(item => organizerSteps[item.code]).map(item => ({
    ...item,
    label: item.code === 'payout' && item.complete ? 'Payment setup confirmed or not needed for free tickets' : organizerSteps[item.code][0],
    href: organizerSteps[item.code][1],
  }))
  const reviews = checklist.filter(item => !organizerSteps[item.code])
  if (reviews.length) steps.push({
    code: 'launch_review',
    label: 'HafaPass launch review',
    complete: reviews.every(item => item.complete),
    detail: reviews.every(item => item.complete) ? 'Launch checks are complete.' : 'Your HafaPass launch coordinator will confirm testing and event-day preparations before publishing.',
  })
  return steps
}
