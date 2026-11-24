import { useTranslation } from 'react-i18next'
import HeroFannedDeck from './HeroFannedDeck'

// Single-block clip-rise entrance: renders plain text inside a single h1 so
// line breaks never change mid-animation or across client-side navigations.
// Opacity stays 1 on frame 0 (LCP-safe); reduced motion keeps it static.
function RiseHeadline({ text, className }) {
  return (
    <div className="hero-rise-clip">
      <h1 className={`hero-rise ${className}`}>{text}</h1>
    </div>
  )
}

/**
 * Self-contained Home hero: dark teal band, full-width stable headline and
 * subline, and the smooth HåfaPass Deck (always leading with the branded
 * HåfaPass default pass, followed by up to 3 featured upcoming events).
 */
export default function HomeHero({ events = [] }) {
  const { t } = useTranslation()

  return (
    <section
      data-header-band="dark"
      className="overflow-x-clip bg-brand-950 pb-12 pt-6 text-white sm:pb-20 sm:pt-12 lg:pb-24 lg:pt-16"
    >
      <div className="mx-auto grid max-w-6xl items-start gap-7 px-4 sm:gap-10 sm:px-6 lg:grid-cols-[minmax(0,6fr)_minmax(0,5fr)] lg:items-center lg:gap-14 lg:px-8">
        <div className="min-w-0">
          <RiseHeadline
            text={t('pass.home.title')}
            className="max-w-lg font-display text-[2.5rem] font-bold leading-[1.06] tracking-tight sm:text-5xl lg:text-6xl"
          />
          <p className="mt-4 max-w-md text-lg leading-relaxed text-brand-100">
            {t('pass.home.lede')}
          </p>
        </div>
        <div className="min-w-0">
          <HeroFannedDeck events={events} />
        </div>
      </div>
    </section>
  )
}
