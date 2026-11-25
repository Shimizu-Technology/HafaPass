import { useTranslation } from 'react-i18next'
import { useSearchParams } from 'react-router-dom'

export default function DoorPaymentReturnPage() {
  const { t } = useTranslation()
  const [search] = useSearchParams()

  return (
    <section className="mx-auto max-w-xl px-4 py-12 sm:py-20">
      <h1 className="font-display text-3xl font-bold text-neutral-950">
        {t(search.get('result') === 'finished' ? 'boxOfficeCard.returnFinished' : 'boxOfficeCard.returnCancelled')}
      </h1>
      <p className="mt-4 text-neutral-700">{t('boxOfficeCard.returnHelp')}</p>
    </section>
  )
}
