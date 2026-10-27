import { useTranslation } from 'react-i18next'
import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import useTranslatedContent from '../hooks/useTranslatedContent'
import MachineTranslationNotice from '../components/MachineTranslationNotice'
import { formatEventDateTime } from '../utils/eventTime'
import EventCard from '../components/EventCard'
import SEO from '../components/SEO'
import BuyerTitleBand from '../components/BuyerTitleBand'

export default function SavedPage() {
  const { t } = useTranslation()
  const [data, setData] = useState(null)
  const [error, setError] = useState(false)
  const [attempt, setAttempt] = useState(0)
  useEffect(() => {
    let active = true
    setError(false)
    setData(null)
    Promise.all([apiClient.get('/me/event_favorites'), apiClient.get('/me/organizer_follows'), apiClient.get('/me/event_reminders')])
      .then(([favorites, follows, reminders]) => { if (active) setData({ events: favorites.data.events, organizers: follows.data.organizers, reminders: reminders.data.reminders }) })
      .catch(() => { if (active) setError(true) })
    return () => { active = false }
  }, [attempt])
  return <div className="public-listing-min-height bg-stone-50">
    <SEO title={t('buyerDiscovery.saved.savedEvents')} description={t('buyerDiscovery.saved.yourHåfaPassFavoritesFollowedOrganizersAndEvent')} />
    <BuyerTitleBand title={t('buyerDiscovery.saved.saved')} description={t('pass.buyer.savedDescription')} />
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-8">
      {error ? <div className="rounded-2xl border border-neutral-200 bg-white p-6"><p role="alert">{t('buyerDiscovery.saved.loadError')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.saved.tryAgain')}</button></div>
        : !data ? <div role="status" aria-label={t('pass.buyer.loadingSaved')} className="flex min-h-48 items-center justify-center"><Loader2 aria-hidden="true" className="h-8 w-8 animate-spin text-brand-700" /></div>
        : <>
          <section aria-labelledby="saved-events-heading">
            <h2 id="saved-events-heading" className="font-display text-2xl font-bold text-neutral-950">{t('buyerDiscovery.saved.favoriteEvents')}</h2>
            {data.events.length ? <div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div> : <p className="mt-3 text-neutral-600">{t('pass.buyer.saveHelp')}</p>}
          </section>
          <div className="mt-9 grid gap-8 md:grid-cols-2">
            <section aria-labelledby="followed-organizers-heading">
              <h2 id="followed-organizers-heading" className="font-display text-xl font-bold text-neutral-950">{t('buyerDiscovery.saved.followedOrganizers')}</h2>
              <div className="mt-3 space-y-2">{data.organizers.map(item => <Link key={item.id} to={`/organizers/${item.slug}`} className="ticket-link flex min-h-11 items-center rounded-xl border border-neutral-200 bg-white p-4 font-semibold text-brand-800 [overflow-wrap:anywhere]">{item.name}</Link>)}{!data.organizers.length && <p className="text-neutral-600">{t('pass.buyer.followHelp')}</p>}</div>
            </section>
            <section aria-labelledby="reminders-heading">
              <h2 id="reminders-heading" className="font-display text-xl font-bold text-neutral-950">{t('buyerDiscovery.saved.reminders')}</h2>
              <div className="mt-3 space-y-2">{data.reminders.filter(item => item.status === 'pending').map(item => <SavedReminder key={item.id} item={item} />)}{!data.reminders.some(item => item.status === 'pending') && <p className="text-neutral-600">{t('pass.buyer.reminderHelp')}</p>}</div>
            </section>
          </div>
          {!data.events.length && <Link to="/events" className="btn-primary mt-8">{t('buyerDiscovery.collections.browseEvents')}</Link>}
        </>}
    </div>
  </div>
}

function SavedReminder({ item }) {
  const { t } = useTranslation()
  const content = useTranslatedContent(item.event)
  return <div className="rounded-xl border border-neutral-200 bg-white p-4">
    <Link to={`/events/${item.event.slug}`} className="ticket-link block min-h-11 rounded-lg [overflow-wrap:anywhere]">
      <span className="font-semibold">{content.title}</span>
      <span className="mt-1 block text-sm text-neutral-600">{t('buyerDiscovery.saved.reminder', { date: formatEventDateTime(item.remind_at, item.event.time_zone, { month: 'numeric', day: 'numeric', year: 'numeric', second: '2-digit' }) })}</span>
    </Link>
    <MachineTranslationNotice {...content.notice} />
  </div>
}
