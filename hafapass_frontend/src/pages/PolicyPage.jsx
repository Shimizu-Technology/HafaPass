import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link, Navigate, useParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'
import PolicyLanguageNotice from '../components/PolicyLanguageNotice'
import { PUBLIC_WEB_URL } from '../utils/site'

export default function PolicyPage() {
  const { t } = useTranslation()
  const { policy } = useParams()
  const [registry, setRegistry] = useState(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    setError(false)
    apiClient.get('/config')
      .then(response => {
        if (response.data.policy_status !== 'approved' || !response.data.policy_effective_date) {
          setError(true)
          return
        }
        setRegistry({
          version: response.data.buyer_terms_version,
          effectiveDate: response.data.policy_effective_date,
          policies: response.data.policies || {},
        })
      })
      .catch(() => setError(true))
  }, [])

  if (error) {
    return (
      <main className="min-h-screen bg-neutral-50 px-4 py-20">
        <div className="mx-auto max-w-xl rounded-2xl border border-red-200 bg-white p-8 text-center">
          <h1 className="text-2xl font-bold text-neutral-950">{t('buyerDiscovery.policy.policyUnavailable')}</h1>
          <p className="mt-3 text-neutral-700">{t('buyerDiscovery.policy.weCouldNotLoadTheAuthoritativePolicy')}</p>
          <button className="btn-primary mt-6" onClick={() => window.location.reload()}>{t('buyerDiscovery.policy.retry')}</button>
        </div>
      </main>
    )
  }

  if (!registry) {
    return <div className="grid min-h-screen place-items-center"><Loader2 className="h-8 w-8 animate-spin text-brand-600" aria-label={t('buyerDiscovery.policy.loadingPolicy')} /></div>
  }

  const content = registry.policies[policy]
  if (!content) return <Navigate to="/policies/buyer-terms" replace />
  const effectiveDate = new Intl.DateTimeFormat('en-US', { month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC' })
    .format(new Date(`${registry.effectiveDate}T00:00:00Z`))

  return (
    <main className="min-h-screen bg-neutral-50 px-4 py-12">
      <SEO title={content.title} description={content.summary} url={`${PUBLIC_WEB_URL}/policies/${policy}`} />
      <article className="mx-auto max-w-3xl rounded-2xl border border-neutral-200 bg-white p-6 shadow-sm sm:p-10">
        <h1 className="mt-3 text-3xl font-bold tracking-tight text-neutral-950">{content.title}</h1>
        <p className="mt-3 text-sm font-medium text-brand-800">{t('buyerDiscovery.policy.effective')} <time dateTime={registry.effectiveDate}>{effectiveDate}</time> · {t('buyerDiscovery.policy.versionLabel', { version: registry.version })}</p>
        <p className="mt-4 text-base leading-7 text-neutral-600">{content.summary}</p>
        <PolicyLanguageNotice className="mt-5" />
        <div className="mt-8 space-y-7">
          {content.sections.map(section => (
            <section key={section.heading}>
              <h2 className="text-lg font-semibold text-neutral-900">{section.heading}</h2>
              {String(section.body).split(/\n\s*\n/).map((paragraph, index) => (
                <p key={index} className="mt-2 leading-7 text-neutral-600">{paragraph}</p>
              ))}
            </section>
          ))}
        </div>
        <nav aria-label={t('buyerDiscovery.policy.otherPolicies')} className="mt-10 border-t border-neutral-200 pt-6 text-sm text-neutral-700">
          <p className="font-semibold text-neutral-900">{t('buyerDiscovery.policy.otherPolicies')}</p>
          <ul className="mt-2 flex flex-wrap gap-x-4">
            {Object.entries(registry.policies).filter(([key]) => key !== policy).map(([key, document]) => (
              <li key={key}><Link className="inline-flex min-h-11 items-center text-brand-800 underline" to={`/policies/${key}`}>{document.title}</Link></li>
            ))}
          </ul>
        </nav>
      </article>
    </main>
  )
}
