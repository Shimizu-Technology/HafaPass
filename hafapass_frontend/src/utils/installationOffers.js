// Keep the browser's one-use offer while buyers navigate between pages.
// The application entry installs the listener before lazy routes mount.
let pendingOffer = null
let initialized = false
const listeners = new Set()
const publish = () => { for (const listener of listeners) listener() }

export const getInstallationOffer = () => pendingOffer
export const subscribeInstallationOffers = listener => {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function initializeInstallationOffers() {
  if (initialized || typeof window === 'undefined') return () => {}
  initialized = true
  const target = window
  const offered = event => { event.preventDefault(); pendingOffer = event; publish() }
  const finished = () => { pendingOffer = null; publish() }
  target.addEventListener('beforeinstallprompt', offered)
  target.addEventListener('appinstalled', finished)
  return () => {
    target.removeEventListener('beforeinstallprompt', offered)
    target.removeEventListener('appinstalled', finished)
    initialized = false
    finished()
  }
}

export function takeInstallationOffer(expected) {
  if (!expected || pendingOffer !== expected) return null
  pendingOffer = null
  publish()
  return expected
}
