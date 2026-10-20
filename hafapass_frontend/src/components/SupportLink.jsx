import { useSupportContact } from '../utils/supportContact'

// A support link that follows the admin-managed contact from /config, so it
// updates as soon as the contact loads. Without a configured mailbox it shows
// the context's own fallback (buyers: ticket recovery) or nothing at all, so
// organizer and admin screens never send people to buyer self-service.
export default function SupportLink({ subject, fallbackHref = null, children, ...props }) {
  const support = useSupportContact()
  if (support.email) return <a href={support.mailto(subject)} {...props}>{children}</a>
  if (fallbackHref) return <a href={fallbackHref} {...props}>{children}</a>
  return null
}
