import { useEffect, useState, useSyncExternalStore } from 'react'
import { useTranslation } from 'react-i18next'
import { Download } from 'lucide-react'
import { getInstallationOffer, subscribeInstallationOffers, takeInstallationOffer } from '../utils/installationOffers'

const isInstalled = () => window.matchMedia?.('(display-mode: standalone)').matches || window.navigator.standalone === true

const hasTouchPointer = () => window.matchMedia?.('(pointer: coarse)').matches === true

// `panel` is the quiet disclosure on My tickets. `action` is the primary hero
// control on the empty Home. With a browser install offer (Chrome, Edge,
// Android) it opens the installer. Without one it expands the manual
// Safari/Android steps, but only on touch devices; desktop browsers without an
// offer get nothing, so order recovery stays the main hero action. On phones an
// offer that arrives late swaps the same primary slot from steps to installer,
// so nothing below it moves.
export default function InstallAppHelp({ variant = 'panel' }) {
  const { t } = useTranslation()
  const [installed, setInstalled] = useState(isInstalled)
  const [touch] = useState(hasTouchPointer)
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
      setError(t('pass.install.promptFailed'))
    } finally {
      setBusy(false)
    }
  }

  if (installed) return null
  const steps = <>
    <p>{t('pass.install.steps')}</p>
    <p className="mt-2">{t('pass.install.offlineNote')}</p>
  </>
  const errorNote = error && <p className="mt-3 text-warning-900" role="status">{error}</p>

  if (variant === 'action') {
    if (installPrompt || busy) return <div>
      <button type="button" onClick={install} disabled={busy} className="btn-primary gap-2">
        <Download className="h-4 w-4" aria-hidden="true" />{busy ? t('pass.install.opening') : t('pass.install.install')}
      </button>
    </div>
    if (!touch) return errorNote ? <div>{errorNote}</div> : null
    return <div>
      <details className="group text-sm text-neutral-700">
        <summary className="btn-primary cursor-pointer list-none gap-2 [&::-webkit-details-marker]:hidden">
          <Download className="h-4 w-4" aria-hidden="true" />{t('pass.install.addToHomeScreen')}
        </summary>
        <div className="mt-3 max-w-md leading-relaxed">{steps}</div>
      </details>
      {errorNote}
    </div>
  }

  return <details className="mb-5 rounded-xl border border-neutral-200 bg-white px-4 text-sm text-neutral-700">
    <summary className="min-h-11 cursor-pointer py-3 font-semibold text-brand-800">{t('pass.install.addToPhone')}</summary>
    <div className="pb-4">
      {steps}
      {(installPrompt || busy) && <button type="button" onClick={install} disabled={busy} className="btn-secondary mt-3 gap-2 !px-4 !py-2 text-sm">
        <Download className="h-4 w-4" aria-hidden="true" />{busy ? t('pass.install.opening') : t('pass.install.install')}
      </button>}
      {errorNote}
    </div>
  </details>
}
