import { useEffect, useSyncExternalStore } from 'react'
import { loadPublicConfig } from '../api/publicConfig'

// Support contact details are data: admins manage SiteSetting platform_email /
// platform_phone and /config exposes them. VITE_SUPPORT_EMAIL is an optional
// build-time override. With nothing configured, links lead to the in-app
// ticket recovery page instead of a broken or hardcoded mailbox.
export const SUPPORT_FALLBACK_PATH = '/orders/recover'
const STORAGE_KEY = 'hafapass_support_contact'
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const EMPTY = Object.freeze({ email: '', phone: '' })

const listeners = new Set()
let contact = readStoredContact()
let loading = null

function clean(value) {
  return typeof value === 'string' ? value.trim() : ''
}

function normalize(value) {
  const email = clean(value?.email)
  return { email: EMAIL_PATTERN.test(email) ? email : '', phone: clean(value?.phone) }
}

// The last known contact survives reloads, so the outage page can still offer it.
function readStoredContact() {
  try {
    return normalize(JSON.parse(window.localStorage.getItem(STORAGE_KEY) || 'null'))
  } catch {
    return EMPTY
  }
}

export function setSupportContact(value) {
  const next = normalize(value)
  if (next.email === contact.email && next.phone === contact.phone) return
  contact = next
  try {
    if (next.email || next.phone) window.localStorage.setItem(STORAGE_KEY, JSON.stringify(next))
    else window.localStorage.removeItem(STORAGE_KEY)
  } catch { /* Unavailable storage only skips the outage fallback. */ }
  listeners.forEach(listener => listener())
}

export function loadSupportContact() {
  loading ||= Promise.resolve()
    .then(loadPublicConfig)
    .then(response => {
      const data = response?.data
      if (!data || typeof data !== 'object') throw new Error('Configuration unavailable')
      setSupportContact({ email: data.support_email, phone: data.support_phone })
    })
    .catch(() => { loading = null })
  return loading
}

export function supportEmail() {
  const override = clean(import.meta.env.VITE_SUPPORT_EMAIL)
  return EMAIL_PATTERN.test(override) ? override : contact.email
}

export function supportPhone() {
  return contact.phone
}

export function supportMailto(subject = 'HåfaPass Support') {
  const email = supportEmail()
  if (!email) return SUPPORT_FALLBACK_PATH
  const recipient = encodeURIComponent(email).replace(/%40/g, '@')
  return `mailto:${recipient}?subject=${encodeURIComponent(subject)}`
}

export function supportTel() {
  const digits = supportPhone().replace(/[^\d+]/g, '')
  return digits ? `tel:${digits}` : ''
}

function subscribe(listener) {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

// Components rendered before /config answers re-render once the contact loads.
export function useSupportContact() {
  useEffect(() => { loadSupportContact() }, [])
  useSyncExternalStore(subscribe, () => contact, () => contact)
  return { email: supportEmail(), phone: supportPhone(), mailto: supportMailto, tel: supportTel() }
}

export function resetSupportContactForTests() {
  contact = EMPTY
  loading = null
  listeners.clear()
}
