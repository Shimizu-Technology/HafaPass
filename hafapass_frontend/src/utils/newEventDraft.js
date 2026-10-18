// Session storage keeps this unfinished form on this browser tab. Never share
// a draft across signed-in accounts or selected organizations.
export const emptyEventForm = {
  title: '', short_description: '', description: '', category: 'other',
  age_restriction: 'all_ages', venue_name: '', venue_address: '', venue_city: 'Guam',
  starts_at: '', ends_at: '', doors_open_at: '', max_capacity: '', cover_image_url: '',
}
export const newEventDraftKey = identity => `hafapass:new-event:v1:${JSON.stringify([identity.authContext?.userId || identity.owner, identity.organizationId])}`
export const hasNewEventDraft = form => Object.keys(emptyEventForm).some(field => form[field] !== emptyEventForm[field])
export function readNewEventDraft(key) {
  try {
    const saved = JSON.parse(window.sessionStorage.getItem(key))
    if (!saved || typeof saved !== 'object' || Array.isArray(saved)) return { form: { ...emptyEventForm }, restored: false }
    const form = Object.fromEntries(Object.entries(emptyEventForm).map(([field, fallback]) => [field, typeof saved[field] === 'string' ? saved[field] : fallback]))
    return { form, restored: hasNewEventDraft(form) }
  } catch { return { form: { ...emptyEventForm }, restored: false } }
}
