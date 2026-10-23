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
  if (error) return <div className="px-4 py-24 text-center"><p role="alert">{t('buyerDiscovery.saved.loadError')}</p><button type="button" className="btn-primary mt-4" onClick={() => setAttempt(value => value + 1)}>{t('buyerDiscovery.saved.tryAgain')}</button></div>
  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  return <div className="mx-auto max-w-6xl px-4 py-10"><SEO title={t('buyerDiscovery.saved.savedEvents')} description={t('buyerDiscovery.saved.yourHåfaPassFavoritesFollowedOrganizersAndEvent')} /><h1 className="font-display text-4xl font-bold">{t('buyerDiscovery.saved.saved')}</h1>
    <section className="mt-9"><h2 className="text-2xl font-bold">{t('buyerDiscovery.saved.favoriteEvents')}</h2>{data.events.length ? <div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div> : <p className="mt-3 text-neutral-500">{t('buyerDiscovery.saved.favoriteAnEventToKeepItHere')}</p>}</section>
    <div className="mt-10 grid gap-8 md:grid-cols-2"><section><h2 className="text-xl font-bold">{t('buyerDiscovery.saved.followedOrganizers')}</h2><div className="mt-3 space-y-2">{data.organizers.map(item => <Link key={item.id} to={`/organizers/${item.slug}`} className="block rounded-xl border border-neutral-200 bg-white p-4 font-semibold hover:border-brand-300">{item.name}</Link>)}{!data.organizers.length && <p className="text-neutral-500">{t('buyerDiscovery.saved.noFollowedOrganizersYet')}</p>}</div></section>
    <section><h2 className="text-xl font-bold">{t('buyerDiscovery.saved.reminders')}</h2><div className="mt-3 space-y-2">{data.reminders.filter(item => item.status === 'pending').map(item => <SavedReminder key={item.id} item={item} />)}{!data.reminders.some(item => item.status === 'pending') && <p className="text-neutral-500">{t('buyerDiscovery.saved.noActiveReminders')}</p>}</div></section></div>
  </div>
}

function SavedReminder({ item }) {
  const { t } = useTranslation()
  const content = useTranslatedContent(item.event)
  return <div className="rounded-xl border border-neutral-200 bg-white p-4">
    <Link to={`/events/${item.event.slug}`} className="block">
      <span className="font-semibold">{content.title}</span>
      <span className="mt-1 block text-sm text-neutral-500">{t('buyerDiscovery.saved.reminder', { date: formatEventDateTime(item.remind_at, item.event.time_zone, { month: 'numeric', day: 'numeric', year: 'numeric', second: '2-digit' }) })}</span>
    </Link>
    <MachineTranslationNotice {...content.notice} />
  </div>
}
