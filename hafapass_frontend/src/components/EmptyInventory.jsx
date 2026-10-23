import { CalendarPlus, ArrowRight } from 'lucide-react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'

// Only show after a successful, unfiltered inventory check. A failed request
// or an empty search result does not establish that the marketplace is empty.
export default function EmptyInventory({ headingAs: Heading = 'h2' }) {
  const { t } = useTranslation()
  return <section className="mx-auto flex public-listing-min-height max-w-6xl items-center px-4 py-12 sm:px-6 sm:py-16 lg:px-8">
    <div className="w-full rounded-2xl border border-neutral-200 bg-white p-6 sm:p-10">
      <CalendarPlus aria-hidden="true" className="mb-5 h-8 w-8 text-brand-800" />
      <Heading className="max-w-xl font-display text-3xl font-bold tracking-tight text-neutral-950 sm:text-4xl">{t('preInventory.title')}</Heading>
      <p className="mt-4 max-w-lg text-base leading-relaxed text-content-muted">{t('preInventory.description')}</p>
      <Link to="/host" className="btn-primary mt-6 inline-flex gap-2">{t('preInventory.listEvent')}<ArrowRight aria-hidden="true" className="h-4 w-4" /></Link>
    </div>
  </section>
}
