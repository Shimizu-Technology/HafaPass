import { CalendarDays, CheckCircle2, Mail, QrCode, RefreshCw, ShieldCheck, TicketCheck } from 'lucide-react'
import SEO from '../components/SEO'

const capabilities = [
  { icon: TicketCheck, title: 'Simple ticketing', text: 'Create events, manage ticket types, and keep orders organized.' },
  { icon: QrCode, title: 'Fast check-in', text: 'QR tickets and a mobile-first scanner for event-day teams.' },
  { icon: ShieldCheck, title: 'Built for Guam', text: 'Local support, practical workflows, and plans for unreliable venue connectivity.' },
]

export default function PrivatePreviewPage({ onRetry }) {
  return (
    <main className="min-h-screen bg-neutral-950 text-white">
      <SEO title="HåfaPass | Private Preview" description="HåfaPass is a Guam-first event ticketing platform currently in private preview." />
      <header className="border-b border-white/10">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-5">
          <a href="/" className="font-display text-xl font-bold tracking-tight">Håfa<span className="text-brand-400">Pass</span></a>
          <span className="rounded-full border border-brand-400/25 bg-brand-500/10 px-3 py-1 text-xs font-semibold uppercase tracking-widest text-brand-300">Private preview</span>
        </div>
      </header>

      <section className="relative overflow-hidden">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(13,158,150,0.22),transparent_45%),radial-gradient(circle_at_80%_80%,rgba(240,86,74,0.14),transparent_42%)]" />
        <div className="relative mx-auto max-w-6xl px-6 py-24 text-center sm:py-32">
          <div className="mx-auto mb-7 inline-flex items-center gap-2 rounded-full border border-white/10 bg-white/5 px-4 py-2 text-sm font-semibold text-white/70">
            <CalendarDays className="h-4 w-4 text-brand-400" /> Product development is temporarily paused
          </div>
          <h1 className="mx-auto max-w-4xl font-display text-4xl font-bold leading-tight tracking-tight sm:text-6xl lg:text-7xl">
            A better way to run events on Guam is still coming.
          </h1>
          <p className="mx-auto mt-7 max-w-2xl text-lg leading-8 text-white/55">
            HåfaPass is not accepting event listings or ticket purchases right now. We are keeping the product in private preview while we focus on the right launch experience for organizers and guests.
          </p>
          <div className="mt-10 flex flex-col items-center justify-center gap-3 sm:flex-row">
            <a
              href="mailto:shimizutechnology@gmail.com?subject=HafaPass%20Private%20Preview%20Updates"
              className="inline-flex items-center justify-center gap-2 rounded-xl bg-brand-500 px-7 py-4 font-semibold text-white shadow-lg shadow-brand-500/20 transition hover:-translate-y-0.5 hover:bg-brand-600"
            >
              <Mail className="h-5 w-5" /> Request launch updates
            </a>
            {onRetry ? (
              <button type="button" onClick={onRetry} className="inline-flex items-center justify-center gap-2 rounded-xl border border-white/20 px-7 py-4 font-semibold text-white transition hover:bg-white/10">
                <RefreshCw className="h-5 w-5" /> Check services again
              </button>
            ) : null}
          </div>
        </div>
      </section>

      <section className="border-y border-white/10 bg-white/[0.03]">
        <div className="mx-auto max-w-6xl px-6 py-16">
          <div className="grid gap-5 md:grid-cols-3">
            {capabilities.map(({ icon: Icon, title, text }) => (
              <article key={title} className="rounded-2xl border border-white/10 bg-neutral-900 p-6">
                <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-brand-500/15 text-brand-300"><Icon /></div>
                <h2 className="mt-5 font-display text-xl font-bold">{title}</h2>
                <p className="mt-2 text-sm leading-6 text-white/50">{text}</p>
              </article>
            ))}
          </div>
          <div className="mt-10 flex items-start gap-3 rounded-2xl border border-brand-400/20 bg-brand-500/10 p-5 text-left">
            <CheckCircle2 className="mt-0.5 shrink-0 text-brand-300" />
            <p className="text-sm leading-6 text-white/65"><strong className="text-white">Already spoke with our team?</strong> Your project notes are still safe. Contact Shimizu Technology when you are ready to restart planning.</p>
          </div>
        </div>
      </section>

      <footer className="px-6 py-8 text-center text-xs text-white/35">A Shimizu Technology product, built in Guam.</footer>
    </main>
  )
}
