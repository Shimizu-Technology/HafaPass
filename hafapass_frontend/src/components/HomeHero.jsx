import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import HeroFannedDeck from './HeroFannedDeck'

let heroRisePlayed = false

// Single-block clip-rise entrance: renders plain text inside a single h1 so
// line breaks never change mid-animation or across client-side navigations.
// Plays once per session; opacity stays 1 on frame 0 (LCP-safe); reduced motion
// keeps it static.
function RiseHeadline({ text, className }) {
  const [shouldAnimate, setShouldAnimate] = useState(() => !heroRisePlayed)

  useEffect(() => {
    const markPlayed = window.setTimeout(() => {
      heroRisePlayed = true
    }, 120)
    const settleAttr = window.setTimeout(() => {
      heroRisePlayed = true
      setShouldAnimate(false)
    }, 640)
    return () => {
      window.clearTimeout(markPlayed)
      window.clearTimeout(settleAttr)
    }
  }, [])

  return (
    <div className="hero-rise-clip">
      <h1
        className={`hero-rise ${className}`}
        data-hero-animate={shouldAnimate ? 'true' : 'false'}
        onAnimationEnd={() => {
          heroRisePlayed = true
          setShouldAnimate(false)
        }}
      >
        {text}
      </h1>
    </div>
  )
}

/**
 * Self-contained Home hero: dark teal band, full-width stable headline and
 * subline (plus desktop search form at lg+), and the smooth HåfaPass Deck
 * (always leading with the branded HåfaPass default pass, followed by up to
 * 3 featured upcoming events).
 */
export default function HomeHero({
  events = [],
  loading = false,
  searchCard = null,
  brandVariant,
  brandSwitcher = null,
}) {
  const { t } = useTranslation()

  return (
    <section
      data-header-band="dark"
      data-testid="home-hero-section"
      className={`overflow-x-clip bg-brand-950 pb-12 text-white sm:pb-20 lg:pb-24 ${
        brandSwitcher ? 'pt-3 sm:pt-5 lg:pt-6' : 'pt-6 sm:pt-12 lg:pt-16'
      }`}
    >
      {brandSwitcher}
      <div className="mx-auto grid max-w-6xl items-start gap-7 px-4 sm:gap-10 sm:px-6 lg:grid-cols-[minmax(0,6fr)_minmax(0,5fr)] lg:gap-14 lg:px-8">
        <div className="min-w-0 lg:pt-4">
          <RiseHeadline
            text={t('pass.home.title')}
            className="max-w-lg font-display text-[2.5rem] font-bold leading-[1.06] tracking-tight sm:text-5xl lg:text-6xl"
          />
          <p className="mt-4 max-w-md text-lg leading-relaxed text-brand-100">
            {t('pass.home.lede')}
          </p>
          {searchCard && <div className="mt-6">{searchCard}</div>}
        </div>
        <div className="min-w-0">
          <HeroFannedDeck events={events} loading={loading} brandVariant={brandVariant} />
        </div>
      </div>
    </section>
  )
}
