import { Languages } from 'lucide-react'
import { useTranslation } from 'react-i18next'

// Small label under organizer text that HåfaPass translated automatically,
// with a switch back to the original. Renders nothing for original text.
export default function MachineTranslationNotice({ showingOriginal, onToggle, className = '' }) {
  const { t } = useTranslation()
  if (!onToggle) return null
  return <p className={`flex flex-wrap items-center gap-x-1.5 text-xs text-neutral-500 ${className}`}>
    <Languages className="h-3.5 w-3.5 shrink-0" aria-hidden="true" />
    <span>{showingOriginal ? t('translation.original') : t('translation.automatic')}</span>
    <span aria-hidden="true">·</span>
    <button type="button" onClick={onToggle} aria-pressed={showingOriginal}
      className="min-h-6 rounded font-medium text-brand-800 underline underline-offset-2 transition-colors duration-150 ease-out-strong hover:text-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus">
      {showingOriginal ? t('translation.showTranslation') : t('translation.showOriginal')}
    </button>
  </p>
}
