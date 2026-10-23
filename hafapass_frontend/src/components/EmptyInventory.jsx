import { CalendarPlus, ArrowRight } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'

// Only show after a successful, unfiltered inventory check. A failed request
// or an empty search result does not establish that the marketplace is empty.
export default function EmptyInventory({ headingAs: Heading = 'h2', embedded = false }) {
  const { t } = useTranslation()
  return <section className={`mx-auto max-w-6xl px-4 py-8 sm:px-6 sm:py-12 lg:px-8 ${embedded ? '' : 'public-listing-min-height'}`}>
    <div className="w-full rounded-2xl border border-neutral-200 bg-white p-6 sm:p-10">
      <CalendarPlus aria-hidden="true" className="mb-5 h-8 w-8 text-brand-800" />
      <Heading className="max-w-xl font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">{t('preInventory.title')}</Heading>
      <p className="mt-4 max-w-lg text-base leading-relaxed text-content-muted">{t('preInventory.description')}</p>
      {!embedded && <div className="mt-6 flex flex-wrap items-center gap-x-6 gap-y-2">
        <Link to="/" className="btn-secondary inline-flex gap-2">{t('buyer.Events.backToEventGuide')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link>
        <Link to="/host" className="inline-flex min-h-11 items-center rounded text-sm font-semibold text-brand-800 underline underline-offset-4 focus-visible:ring-2 focus-visible:ring-focus focus-visible:ring-offset-2">{t('preInventory.listEvent')}</Link>
      </div>}
    </div>
  </section>
}
