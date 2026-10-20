import { PUBLIC_WEB_URL } from './site'

// Format rules mirror PublicSlug on the API. Reserved words and links other
// events use (now or before) are checked by the API's availability endpoint.
export const EVENT_LINK_MIN = 3
export const EVENT_LINK_MAX = 80
const FORMAT = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export const eventLinkUrl = slug => `${PUBLIC_WEB_URL}/events/${slug}`

// Typing "Summer Jam 2026" produces "summer-jam-2026" without fighting the
// cursor: only case and separators change while the organizer types.
export const normalizeEventLinkInput = value => value.toLowerCase().replace(/[\s_]+/g, '-')

export function eventLinkFormatError(slug) {
  if (!slug) return 'Enter a link name'
  if (slug.length < EVENT_LINK_MIN || slug.length > EVENT_LINK_MAX) {
    return `Use ${EVENT_LINK_MIN} to ${EVENT_LINK_MAX} characters`
  }
  if (!FORMAT.test(slug)) return 'Use only lowercase letters, numbers, and single hyphens between words'
  return null
}
