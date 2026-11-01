import { useTranslation } from 'react-i18next'
import { RefreshCw, RotateCcw } from 'lucide-react'
import Ticket from './Ticket'
import HafaPassMark from './HafaPassMark'

// Rendered by the root error boundary, so it avoids router links and any
// data: the actions are a retry, a full reload and a plain link home.
export default function ErrorFallback({ error, resetError }) {
  const { t } = useTranslation()
  return (
    <main className="flex min-h-dvh items-center justify-center bg-brand-950 px-4 py-12 sm:px-6">
      <Ticket
        className="w-full max-w-md"
        topClassName="px-6 pb-7 pt-6 sm:px-8 sm:pt-8"
        stubClassName="px-6 pb-6 pt-7 sm:px-8 sm:pb-8"
        stub={<div className="grid gap-3">
          <button type="button" onClick={resetError} className="btn-primary w-full gap-2">
            <RotateCcw className="h-4 w-4" aria-hidden="true" />{t('buyer.ErrorFallback.tryAgain')}</button>
          <button type="button" onClick={() => window.location.reload()} className="btn-secondary w-full gap-2">
            <RefreshCw className="h-4 w-4" aria-hidden="true" />{t('buyer.ErrorFallback.reloadHafaPass')}</button>
          <a href="/" className="inline-flex min-h-11 items-center justify-center font-semibold text-brand-700 underline underline-offset-4">{t('buyer.ErrorFallback.goHome')}</a>
        </div>}
      >
        <section aria-labelledby="application-error-title">
          <div className="flex items-center gap-2.5">
            <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-brand-700"><HafaPassMark className="h-5 w-5 text-white" /></span>
            <p className="text-sm font-semibold text-brand-700">{t('buyer.ErrorFallback.hafapassRecovery')}</p>
          </div>
          <h1 id="application-error-title" className="mt-5 font-display text-2xl font-bold tracking-tight text-neutral-950 sm:text-3xl">{t('buyer.ErrorFallback.somethingInterruptedThisPage')}</h1>
          <p className="mt-3 text-base leading-relaxed text-content-muted">{t('buyer.ErrorFallback.theIssueHasBeenRecordedWhenMonitoringIs')}</p>

          {import.meta.env.DEV && error?.message && (
            <details className="mt-5 rounded-xl border border-neutral-200 bg-neutral-50 p-4 text-left">
              <summary className="cursor-pointer text-sm font-semibold text-neutral-700">{t('buyer.ErrorFallback.developmentDetails')}</summary>
              <pre className="mt-3 overflow-auto whitespace-pre-wrap text-xs leading-5 text-neutral-800">{error.message}</pre>
            </details>
          )}
        </section>
      </Ticket>
    </main>
  )
}
