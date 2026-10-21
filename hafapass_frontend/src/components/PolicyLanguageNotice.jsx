import { useTranslation } from 'react-i18next'
import { languageFor } from '../utils/locale'

// Policies are written and enforced in English. When the app is in another
// language, say so plainly next to the policy text.
export default function PolicyLanguageNotice({ className = '' }) {
  const { t, i18n } = useTranslation()
  if (languageFor(i18n.language).code === 'en') return null
  return <p role="note" className={`rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-sm leading-6 text-neutral-700 ${className}`}>
    {t('policy.englishGoverns')}
  </p>
}
