import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'
import api from '../api/client'
import SavedPage from './SavedPage'
import CollectionsPage from './CollectionsPage'
import VenuePage from './VenuePage'
import OrganizerPage from './OrganizerPage'
import CollectionPage from './CollectionPage'
import PrivacyRequestsPage from './PrivacyRequestsPage'

vi.mock('../api/client', async original => ({ ...await original(), default: { get: vi.fn() } }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/EventCard', () => ({ default: ({ event }) => <p>{event.title}</p> }))
const show = (Component, path = '/', route = '/') => render(<MemoryRouter initialEntries={[route]}><Routes><Route path={path} element={<Component />} /></Routes></MemoryRouter>)
beforeEach(() => { api.get.mockReset(); vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '') })

it('keeps a failed saved-items request separate from all three empty lists, then retries', async () => {
  api.get.mockImplementation(url => url === '/me/organizer_follows' ? Promise.reject(new Error('offline')) : Promise.resolve({ data: { events: [], reminders: [] } }))
  show(SavedPage)
  expect(await screen.findByRole('alert')).toHaveTextContent("We couldn't load your saved items.")
  expect(screen.queryByText('Save an event to find it here.')).not.toBeInTheDocument()
  expect(screen.queryByText('No followed organizers yet.')).not.toBeInTheDocument()
  expect(screen.queryByText('No active reminders.')).not.toBeInTheDocument()
  api.get.mockResolvedValue({ data: { events: [], organizers: [], reminders: [] } })
  await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
  expect(await screen.findByText('Save an event to find it here.')).toBeInTheDocument()
  expect(api.get).toHaveBeenCalledTimes(6)
})

it('shows a discover failure with retry, then the genuine empty state', async () => {
  api.get.mockRejectedValueOnce(new Error('offline')).mockImplementation(url => Promise.resolve({ data: url === '/events' ? { events: [{ id: 1 }] } : { collections: [] } }))
  show(CollectionsPage)
  expect(await screen.findByRole('alert')).toHaveTextContent("We couldn't load featured collections.")
  expect(screen.queryByText(/No featured collections yet/)).not.toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
  expect(await screen.findByText('No featured collections yet. Browse events to see current listings.')).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Browse events' })).toHaveAttribute('href', '/events')
})

it('shows hosting on Discover when both collections and public inventory are empty', async () => {
  api.get.mockImplementation(url => Promise.resolve({ data: url === '/events' ? { events: [], meta: { total_count: 0 } } : { collections: [] } }))
  show(CollectionsPage)
  expect(await screen.findByRole('heading', { name: 'Events are coming soon' })).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'List your event' })).toHaveAttribute('href', '/host')
  expect(screen.queryByRole('link', { name: 'Browse events' })).not.toBeInTheDocument()
})

it('keeps curated Discover content when collections contain public events', async () => {
  api.get.mockResolvedValue({ data: { collections: [{ id: 1, slug: 'weekend', title: 'Weekend picks', events: [{ id: 1, title: 'Live music' }] }] } })
  show(CollectionsPage)
  expect(await screen.findByText('Live music')).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'View all' })).toHaveAttribute('href', '/collections/weekend')
  expect(api.get).toHaveBeenCalledTimes(1)
})

it.each([
  [VenuePage, '/venues/:slug', '/venues/empty', 'No upcoming events are listed for this venue.'],
  [OrganizerPage, '/organizers/:slug', '/organizers/empty', 'This organizer has no upcoming events listed.'],
  [CollectionPage, '/collections/:slug', '/collections/empty', 'This collection has no events listed right now.'],
])('explains an empty public event grid and links to current listings', async (Page, path, route, message) => {
  api.get.mockResolvedValue({ data: { name: 'QA', title: 'QA', events: [], meta: {} } })
  show(Page, path, route)
  expect(await screen.findByText(message)).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'Browse events' })).toHaveAttribute('href', '/events')
})

it('shows privacy loading, failure and retry without falsely reporting an empty history', async () => {
  let rejectLoad
  api.get.mockReturnValueOnce(new Promise((_, reject) => { rejectLoad = reject }))
  show(PrivacyRequestsPage, '/privacy/requests', '/privacy/requests')
  expect(screen.getByRole('status')).toHaveTextContent('Loading your requests…')
  expect(screen.queryByText('No requests yet.')).not.toBeInTheDocument()
  await act(async () => rejectLoad(new Error('offline')))
  expect(await screen.findByRole('alert')).toHaveTextContent("We couldn't load your requests.")
  expect(screen.queryByText('No requests yet.')).not.toBeInTheDocument()
  api.get.mockResolvedValue({ data: { requests: [] } })
  await userEvent.click(screen.getByRole('button', { name: 'Try again' }))
  expect(await screen.findByText('No requests yet.')).toBeInTheDocument()
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})


it.each([
  [VenuePage, '/venues/:slug', '/venues/fixture?page=2'],
  [OrganizerPage, '/organizers/:slug', '/organizers/fixture?page=2'],
  [CollectionPage, '/collections/:slug', '/collections/fixture?page=2'],
])('recovers an empty pagination page without claiming the whole listing is empty', async (Page, path, route) => {
  const data = { name: 'QA', title: 'QA', events: [], meta: { total_count: 1, current_page: 2, total_pages: 1 } }
  api.get.mockResolvedValueOnce({ data }).mockResolvedValue({ data: { ...data, events: [{ id: 1, title: 'Current event' }], meta: { total_count: 1, current_page: 1, total_pages: 1 } } })
  show(Page, path, route)
  expect(await screen.findByText('No events on this page.')).toBeInTheDocument()
  expect(screen.queryByText(/no upcoming events|No upcoming events|no events listed right now/)).not.toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: 'Back to first page' }))
  expect(await screen.findByText('Current event')).toBeInTheDocument()
  expect(api.get).toHaveBeenLastCalledWith(expect.any(String), { params: { page: 1 } })
})
