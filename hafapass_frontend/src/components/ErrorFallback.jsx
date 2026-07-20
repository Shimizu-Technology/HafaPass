import { AlertTriangle, RefreshCw, RotateCcw } from 'lucide-react'

export default function ErrorFallback({ error, resetError }) {
  return (
    <main className="relative flex min-h-screen items-center justify-center overflow-hidden bg-neutral-950 px-6 py-16 text-neutral-100">
      <div className="pointer-events-none absolute inset-0 opacity-40" aria-hidden="true">
        <div className="absolute -left-24 top-1/4 h-72 w-72 rounded-full bg-brand-500/20 blur-3xl" />
        <div className="absolute -right-24 bottom-1/4 h-72 w-72 rounded-full bg-accent-500/15 blur-3xl" />
      </div>

      <section className="relative w-full max-w-lg rounded-[2rem] border border-white/10 bg-white/[0.06] p-8 shadow-2xl shadow-black/30 backdrop-blur-xl sm:p-10" aria-labelledby="application-error-title">
        <div className="flex h-12 w-12 items-center justify-center rounded-2xl border border-accent-300/20 bg-accent-400/10 text-accent-300">
          <AlertTriangle className="h-6 w-6" aria-hidden="true" />
        </div>

        <p className="mt-7 text-xs font-bold uppercase tracking-[0.24em] text-brand-300">HåfaPass recovery</p>
        <h1 id="application-error-title" className="mt-3 text-3xl font-bold tracking-tight text-white sm:text-4xl">
          Something interrupted this page.
        </h1>
        <p className="mt-4 max-w-md text-base leading-7 text-neutral-300">
          The issue has been recorded when monitoring is configured. Try the page again, or reload HåfaPass to start fresh.
        </p>

        <div className="mt-8 grid gap-3 sm:grid-cols-2">
          <button type="button" onClick={resetError} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl bg-brand-400 px-5 py-3 font-semibold text-neutral-950 transition-colors hover:bg-brand-300 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-200 focus-visible:ring-offset-2 focus-visible:ring-offset-neutral-950">
            <RotateCcw className="h-4 w-4" aria-hidden="true" />
            Try again
          </button>
          <button type="button" onClick={() => window.location.reload()} className="inline-flex min-h-11 items-center justify-center gap-2 rounded-xl border border-white/15 bg-white/[0.06] px-5 py-3 font-semibold text-white transition-colors hover:bg-white/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-white/70 focus-visible:ring-offset-2 focus-visible:ring-offset-neutral-950">
            <RefreshCw className="h-4 w-4" aria-hidden="true" />
            Reload HåfaPass
          </button>
        </div>

        {import.meta.env.DEV && error?.message && (
          <details className="mt-7 rounded-xl border border-white/10 bg-black/20 p-4 text-left">
            <summary className="cursor-pointer text-sm font-semibold text-neutral-300">Development details</summary>
            <pre className="mt-3 overflow-auto whitespace-pre-wrap text-xs leading-5 text-accent-200">{error.message}</pre>
          </details>
        )}
      </section>
    </main>
  )
}
