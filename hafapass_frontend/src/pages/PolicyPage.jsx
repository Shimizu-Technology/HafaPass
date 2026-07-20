import { useEffect, useState } from 'react'
import { Link, Navigate, useParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import SEO from '../components/SEO'

export default function PolicyPage() {
  const { policy } = useParams()
  const [registry, setRegistry] = useState(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    setError(false)
    apiClient.get('/config')
      .then(response => setRegistry({
        version: response.data.buyer_terms_version,
        policies: response.data.policies || {},
      }))
      .catch(() => setError(true))
  }, [])

  if (error) {
    return (
      <main className="min-h-screen bg-neutral-50 px-4 py-20">
        <div className="mx-auto max-w-xl rounded-2xl border border-red-200 bg-white p-8 text-center">
          <h1 className="text-2xl font-bold text-neutral-950">Policy unavailable</h1>
          <p className="mt-3 text-neutral-700">We could not load the authoritative policy text. Please retry before purchasing or publishing.</p>
          <button className="btn-primary mt-6" onClick={() => window.location.reload()}>Retry</button>
        </div>
      </main>
    )
  }

  if (!registry) {
    return <div className="grid min-h-screen place-items-center"><Loader2 className="h-8 w-8 animate-spin text-brand-600" aria-label="Loading policy" /></div>
  }

  const content = registry.policies[policy]
  if (!content) return <Navigate to="/policies/buyer-terms" replace />

  return (
    <main className="min-h-screen bg-neutral-50 px-4 py-12">
      <SEO title={`${content.title} — HafaPass`} description={content.summary} />
      <article className="mx-auto max-w-3xl rounded-2xl border border-neutral-200 bg-white p-6 shadow-sm sm:p-10">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-brand-800">Pilot policy · version {registry.version}</p>
        <h1 className="mt-3 text-3xl font-bold tracking-tight text-neutral-950">{content.title}</h1>
        <p className="mt-4 text-base leading-7 text-neutral-600">{content.summary}</p>
        <div className="mt-5 rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm leading-6 text-amber-900" role="note">
          This is an engineering-ready pilot draft, not a representation of completed legal approval. Production sales remain blocked until Guam/US counsel, privacy, accounting, and payment-provider reviewers approve and date the governing documents.
        </div>
        <div className="mt-8 space-y-7">
          {content.sections.map(section => (
            <section key={section.heading}>
              <h2 className="text-lg font-semibold text-neutral-900">{section.heading}</h2>
              <p className="mt-2 leading-7 text-neutral-600">{section.body}</p>
            </section>
          ))}
        </div>
        <p className="mt-10 border-t border-neutral-200 pt-6 text-sm text-neutral-700">
          See also <Link className="text-brand-800 underline" to="/policies/privacy">Privacy</Link>,{' '}
          <Link className="text-brand-800 underline" to="/policies/refunds">Refunds</Link>, and{' '}
          <Link className="text-brand-800 underline" to="/policies/acceptable-use">Acceptable Use</Link>.
        </p>
      </article>
    </main>
  )
}
