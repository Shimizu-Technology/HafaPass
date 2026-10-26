import { useEffect, useState, useSyncExternalStore } from 'react'
import { Download } from 'lucide-react'
import { getInstallationOffer, subscribeInstallationOffers, takeInstallationOffer } from '../utils/installationOffers'

const isInstalled = () => window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone === true

export default function InstallAppHelp() {
  const [installed, setInstalled] = useState(isInstalled)
  const installPrompt = useSyncExternalStore(subscribeInstallationOffers, getInstallationOffer, () => null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    const finished = () => setInstalled(true)
    const displayMode = window.matchMedia?.('(display-mode: standalone)')
    const changed = () => setInstalled(isInstalled())
    window.addEventListener('appinstalled', finished)
    displayMode?.addEventListener('change', changed)
    return () => {
      window.removeEventListener('appinstalled', finished)
      displayMode?.removeEventListener('change', changed)
    }
  }, [])

  const install = async () => {
    if (busy) return
    const offer = takeInstallationOffer(installPrompt)
    if (!offer) return
    setBusy(true)
    setError(null)
    try {
      await offer.prompt()
      await offer.userChoice
    } catch {
      setError('Use your browser’s menu to add HåfaPass to your home screen.')
    } finally {
      setBusy(false)
    }
  }

  if (installed) return null
  return <details className="mb-5 rounded-xl border border-neutral-200 bg-white px-4 text-sm text-neutral-700">
    <summary className="min-h-11 cursor-pointer py-3 font-semibold text-brand-800">Add HåfaPass to your phone</summary>
    <div className="pb-4">
      <p>Open your browser’s menu and choose Install app or Add to Home Screen. On iPhone or iPad, open HåfaPass in Safari, then choose Share and Add to Home Screen.</p>
      <p className="mt-2">Download your ticket before going offline. Installing HåfaPass does not save every ticket on your phone.</p>
      {(installPrompt || busy) && <button type="button" onClick={install} disabled={busy} className="btn-secondary mt-3 gap-2 !px-4 !py-2 text-sm">
        <Download className="h-4 w-4" aria-hidden="true" />{busy ? 'Opening installation…' : 'Install HåfaPass'}
      </button>}
      {error && <p className="mt-3 text-amber-900" role="status">{error}</p>}
    </div>
  </details>
}
