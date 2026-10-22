import { useTranslation } from 'react-i18next'
import { CalendarDays, Mail, RefreshCw } from 'lucide-react'
import SEO from '../components/SEO'
import { useSupportContact } from '../utils/supportContact'

export default function PrivatePreviewPage({ onRetry }) {
  const { t } = useTranslation()
  const support = useSupportContact()
  return (
    <main className="min-h-screen bg-neutral-950 text-white">
      <SEO title={t('buyerDiscovery.privatePreview.håfapassConnectionUnavailable')} description={t('buyerDiscovery.privatePreview.håfapassServicesAreTemporarilyUnavailableRetryYour')} />
      <header className="border-b border-white/10">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
          <a href="/" className="font-display text-xl font-bold tracking-tight">Håfa<span className="text-brand-400">Pass</span></a>
          <span className="rounded-full border border-brand-400/25 bg-brand-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-widest text-brand-300">{t('buyerDiscovery.privatePreview.privatePreview')}</span>
        </div>
      </header>

      <section className="relative overflow-hidden">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(13,158,150,0.22),transparent_45%),radial-gradient(circle_at_80%_80%,rgba(240,86,74,0.14),transparent_42%)]" />
        <div className="relative mx-auto max-w-6xl px-6 py-24 text-center sm:py-32">
          <div className="mx-auto mb-7 inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-semibold text-white/70">
            <CalendarDays className="h-4 w-4 text-brand-400" />{t('buyerDiscovery.privatePreview.connectionToHåfaPassIsUnavailable')}</div>
          <h1 className="mx-auto max-w-4xl font-display text-4xl font-bold leading-tight tracking-tight sm:text-6xl lg:text-7xl">{t('buyerDiscovery.privatePreview.pleaseTryConnectingAgain')}</h1>
          <p className="mx-auto mt-7 max-w-2xl text-lg leading-8 text-white/55">{t('buyerDiscovery.privatePreview.weCannotLoadEventListingsOrCheckout')}</p>
          <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <a
              href={support.mailto()}
              className="inline-flex items-center justify-center gap-2 rounded-xl bg-brand-500 px-7 py-4 font-semibold text-white shadow-lg shadow-brand-500/20 transition hover:-translate-y-0.5 hover:bg-brand-600"
            >
              <Mail className="h-5 w-5" />{t('buyerDiscovery.privatePreview.contactSupport')}</a>
            {onRetry ? (
              <button type="button" onClick={onRetry} className="inline-flex items-center justify-center gap-2 rounded-xl border border-white/20 px-7 py-4 font-semibold text-white transition hover:bg-white/10">
                <RefreshCw className="h-5 w-5" />{t('buyerDiscovery.privatePreview.checkServicesAgain')}</button>
            ) : null}
          </div>
        </div>
      </section>

      <section className="border-y border-white/10 bg-white/[0.03] px-6 py-8 text-center">
        <p className="mx-auto max-w-xl text-sm leading-6 text-white/70">{t('buyerDiscovery.privatePreview.eventStaffCanReopenThe')}<a className="font-semibold text-brand-300 underline" href="/dashboard/scanner">{t('buyerDiscovery.privatePreview.ticketScanner')}</a>{t('buyerDiscovery.privatePreview.onADevicePreparedBeforeTheEvent')}</p>
      </section>

      <footer className="px-6 py-8 text-center text-xs text-white/35">{t('buyerDiscovery.privatePreview.aShimizuTechnologyProductBuiltInGuam')}</footer>
    </main>
  )
}
