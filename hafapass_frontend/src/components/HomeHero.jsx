import { Fragment } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Ticket as TicketIcon } from 'lucide-react'
import Ticket from './Ticket'
import { HostingStub } from './EmptyInventory'
import InstallAppHelp from './InstallAppHelp'
import FeaturedPassStub from './FeaturedPassStub'

// The page's one entrance: words rise from an overflow: clip mask in CSS so
// the headline paints at opacity 1 on frame 0 (LCP-safe). Reduced motion
// shows it still immediately.
function RiseHeadline({ text, className }) {
  const words = text.split(' ')
  return (
    <h1 className={`hero-rise ${className}`}>
      {words.map((word, index) => (
        <Fragment key={index}>
          <span className="hero-rise-mask">
            <span className="hero-rise-word" style={{ '--word': index }}>{word}</span>
          </span>
          {index < words.length - 1 ? ' ' : null}
        </Fragment>
      ))}
    </h1>
  )
}

/**
 * Self-contained Home hero: dark teal band, LCP-safe clip-mask headline,
 * desktop search card slot, and a completely flat FeaturedPassStub (or the
 * loading / error / empty-inventory ticket). Swappable for other hero
 * explorations without changing the rest of HomePage.
 */
export default function HomeHero({
  discovery,
  wide,
  loading,
  loadError,
  inventoryEmpty,
  featuredEvent,
  searchCard,
  findTicketLink,
  onRetry,
}) {
  const { t } = useTranslation()

  return (
    <section data-header-band="dark" className="bg-brand-950 pb-12 pt-6 text-white sm:pb-20 sm:pt-12 lg:pb-24 lg:pt-16">
      {/* Top-aligned, with the text column holding the loaded height in every
          state, so events arriving (or not) never shift the page. */}
      <div className="mx-auto grid max-w-6xl items-start gap-7 px-4 sm:gap-10 sm:px-6 lg:grid-cols-[minmax(0,6fr)_minmax(0,5fr)] lg:gap-16 lg:px-8">
        <div className="min-w-0 lg:min-h-[31rem]">
          <RiseHeadline
            text={t('pass.home.title')}
            className="max-w-lg font-display text-[2.5rem] font-bold leading-[1.06] tracking-tight sm:text-5xl lg:text-6xl"
          />
          <p className="mt-4 max-w-md text-lg leading-relaxed text-brand-100">{t('pass.home.lede')}</p>
          {discovery && wide && <div className="mt-6">{searchCard}</div>}
        </div>
        {/* Hosting is pitched once: in the hero stub while loading, then by the planning ticket. */}
        {discovery ? (
          <FeaturedPassStub event={featuredEvent} />
        ) : (
          <Ticket
            className="hero-ticket text-content"
            stub={loading ? <HostingStub /> : inventoryEmpty ? (
              <div className="flex flex-col items-start gap-1 px-6 py-5 sm:px-8">
                <InstallAppHelp variant="action" />
                {findTicketLink}
              </div>
            ) : (
              <div className="px-6 py-3 sm:px-8">{findTicketLink}</div>
            )}
          >
            <div className={`home-ticket-content px-6 py-6 sm:px-8 sm:py-7 ${inventoryEmpty ? 'home-ticket-empty' : ''}`} aria-busy={loading}>
              {loading ? (
                <div className="flex h-full flex-col items-start justify-center gap-3">
                  <p role="status" className="text-content-muted">{t('buyer.Home.loadingUpcomingEvents')}</p>
                  <Link to="/events" className="btn-secondary">{t('buyer.Home.browseEvents')}</Link>
                </div>
              ) : loadError ? (
                <div role="alert">
                  <h2 className="font-display text-2xl font-bold">{t('buyer.Home.eventsCouldntLoad')}</h2>
                  <p className="mt-3 text-content-muted">{t('buyer.Home.pleaseTryAgainToSeeWhatsComingUp')}</p>
                  <div className="mt-4 flex flex-wrap gap-3">
                    <button type="button" onClick={onRetry} className="btn-primary">{t('buyer.Home.retryEvents')}</button>
                    <Link to="/events" className="btn-secondary">{t('buyer.Home.browseEvents')}</Link>
                  </div>
                </div>
              ) : inventoryEmpty ? (
                <div className="flex h-full flex-col items-start justify-center">
                  <TicketIcon aria-hidden="true" className="mb-4 h-8 w-8 text-brand-700" />
                  <h2 className="max-w-sm font-display text-2xl font-bold leading-tight sm:text-3xl">{t('pass.home.firstEvents')}</h2>
                  <p className="mt-3 max-w-sm leading-relaxed text-content-muted">{t('pass.home.checkBack')}</p>
                </div>
              ) : null}
            </div>
          </Ticket>
        )}
      </div>
    </section>
  )
}
