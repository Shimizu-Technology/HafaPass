// Readable labels for the raw enum values admin pages receive from the API.
const labels = {
  draft: 'Draft', published: 'Published', postponed: 'Postponed', cancelled: 'Cancelled', completed: 'Completed', archived: 'Archived',
  pending: 'Pending', failed: 'Failed', refunded: 'Refunded', partially_refunded: 'Partially refunded',
  attendee: 'Attendee', organizer: 'Organizer', support: 'Support', admin: 'Admin',
  unverified: 'Unverified', verified: 'Verified', rejected: 'Rejected', suspended: 'Suspended',
}

export function adminLabel(value) {
  if (!value) return ''
  if (labels[value]) return labels[value]
  const words = String(value).replaceAll('_', ' ')
  return words.charAt(0).toUpperCase() + words.slice(1)
}
