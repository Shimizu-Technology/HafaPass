import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import EventCard from '../components/EventCard'
import SEO from '../components/SEO'

export default function SavedPage() {
  const [data, setData] = useState(null)
  useEffect(() => {
    Promise.all([apiClient.get('/me/event_favorites'), apiClient.get('/me/organizer_follows'), apiClient.get('/me/event_reminders')])
      .then(([favorites, follows, reminders]) => setData({ events: favorites.data.events, organizers: follows.data.organizers, reminders: reminders.data.reminders }))
      .catch(() => setData({ events: [], organizers: [], reminders: [] }))
  }, [])
  if (!data) return <Loader2 className="mx-auto mt-24 h-8 w-8 animate-spin text-brand-500" />
  return <div className="mx-auto max-w-6xl px-4 py-10"><SEO title="Saved events" description="Your HafaPass favorites, followed organizers, and event reminders." /><h1 className="font-display text-4xl font-bold">Saved</h1>
    <section className="mt-9"><h2 className="text-2xl font-bold">Favorite events</h2>{data.events.length ? <div className="mt-5 grid gap-6 sm:grid-cols-2 lg:grid-cols-3">{data.events.map(event => <EventCard key={event.id} event={event} />)}</div> : <p className="mt-3 text-neutral-500">Favorite an event to keep it here.</p>}</section>
    <div className="mt-10 grid gap-8 md:grid-cols-2"><section><h2 className="text-xl font-bold">Followed organizers</h2><div className="mt-3 space-y-2">{data.organizers.map(item => <Link key={item.id} to={`/organizers/${item.slug}`} className="block rounded-xl border border-neutral-200 bg-white p-4 font-semibold hover:border-brand-300">{item.name}</Link>)}{!data.organizers.length && <p className="text-neutral-500">No followed organizers yet.</p>}</div></section>
    <section><h2 className="text-xl font-bold">Reminders</h2><div className="mt-3 space-y-2">{data.reminders.filter(item => item.status === 'pending').map(item => <Link key={item.id} to={`/events/${item.event.slug}`} className="block rounded-xl border border-neutral-200 bg-white p-4"><span className="font-semibold">{item.event.title}</span><span className="mt-1 block text-sm text-neutral-500">Reminder {new Date(item.remind_at).toLocaleString()}</span></Link>)}{!data.reminders.some(item => item.status === 'pending') && <p className="text-neutral-500">No active reminders.</p>}</div></section></div>
  </div>
}
