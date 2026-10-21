import { Languages } from 'lucide-react'
import { useTranslation } from 'react-i18next'

// Small label under organizer text that HåfaPass translated automatically,
// with a switch back to the original. Renders nothing for original text.
// `tone="dark"` for use on the event hero image.
export default function MachineTranslationNotice({ showingOriginal, onToggle, tone = 'light', className = '', labelOnly = false, as: Container = 'p' }) {
  const { t } = useTranslation()
  if (!onToggle && !labelOnly) return null
  const dark = tone === 'dark'
  return <Container className={`flex flex-wrap items-center gap-x-1.5 text-xs ${dark ? 'text-neutral-200' : 'text-neutral-500'} ${className}`}>
    <Languages className="h-3.5 w-3.5 shrink-0" aria-hidden="true" />
    <span>{showingOriginal ? t('translation.original') : t('translation.automatic')}</span>
    {!labelOnly && <span aria-hidden="true">·</span>}
    {!labelOnly && <button type="button" onClick={onToggle} aria-pressed={showingOriginal}
      className={`min-h-6 rounded font-medium underline underline-offset-2 transition-colors duration-150 ease-out-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-focus ${dark ? 'text-white hover:text-brand-200' : 'text-brand-800 hover:text-brand-900'}`}>
      {showingOriginal ? t('translation.showTranslation') : t('translation.showOriginal')}
    </button>}
  </Container>
}
