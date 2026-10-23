import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { createInstance } from 'i18next'
import { I18nextProvider } from 'react-i18next'
import en from '../locales/en.json'
import HostPage from './HostPage'
import OrganizerPage from './OrganizerPage'
import VenuePage from './VenuePage'
import SavedPage from './SavedPage'
import CollectionsPage from './CollectionsPage'
import CollectionPage from './CollectionPage'
import PrivatePreviewPage from './PrivatePreviewPage'
import SignInPage from './SignInPage'
import SignUpPage from './SignUpPage'
import PolicyPage from './PolicyPage'

const api = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('../api/client', () => ({ default: api }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, isSignedIn: false }), SignIn: () => null, SignUp: () => null }))

function fakeKeys(value, prefix = '') {
  return Object.fromEntries(Object.entries(value).map(([key, child]) => [key,
    typeof child === 'string' ? `TEST:${prefix}${key}` : fakeKeys(child, `${prefix}${key}.`),
  ]))
}

async function renderPage(Component, route = '/', path = '/') {
  const i18n = createInstance()
  await i18n.init({ lng: 'xx', fallbackLng: 'en', resources: { xx: { translation: fakeKeys(en) }, en: { translation: en } }, interpolation: { escapeValue: false } })
  return render(<I18nextProvider i18n={i18n}><MemoryRouter initialEntries={[route]}><Routes><Route path={path} element={<Component />} /></Routes></MemoryRouter></I18nextProvider>)
}

beforeEach(() => {
  api.get.mockImplementation(url => {
    if (url === '/config') return Promise.resolve({ data: { service_fee_percent: '5.0', service_fee_flat_cents: 100, buyer_terms_version: '2026-10-22', policy_status: 'approved', policy_effective_date: '2026-10-22', policies: { 'buyer-terms': { title: 'Authoritative English policy', summary: 'English policy summary', sections: [{ heading: 'English legal heading', body: 'English legal body' }] } } } })
    if (url === '/marketplace_collections') return Promise.resolve({ data: { collections: [] } })
    if (url.startsWith('/me/')) return Promise.resolve({ data: { events: [], organizers: [], reminders: [] } })
    return Promise.resolve({ data: { name: 'Fixture name', title: 'Fixture title', events: [], meta: {}, completed_events: 2, tickets_issued: 3, followers: 4 } })
  })
})

describe('buyer discovery pages translate visible chrome with a fake locale', () => {
  it.each([
    [HostPage, 'host.hostYourEventWithHåfaPass'],
    [OrganizerPage, 'organizer.upcomingEvents', '/organizers/fixture', '/organizers/:slug'],
    [VenuePage, 'venue.upcomingEvents', '/venues/fixture', '/venues/:slug'],
    [SavedPage, 'saved.saved'],
    [CollectionsPage, 'collections.discoverGuam'],
    [CollectionPage, null, '/collections/fixture', '/collections/:slug'],
    [PrivatePreviewPage, 'privatePreview.pleaseTryConnectingAgain'],
    [SignInPage, 'signIn.signIn'],
    [SignUpPage, 'signUp.signUp'],
    [PolicyPage, 'policy.otherPolicies', '/policies/buyer-terms', '/policies/:policy'],
  ])('renders %s in the selected language', async (Component, heading, route, path) => {
    const view = await renderPage(Component, route, path)
    if (Component === CollectionsPage) expect(await screen.findByText('TEST:preInventory.title')).toBeInTheDocument()
    else if (heading) expect(await screen.findByText(`TEST:buyerDiscovery.${heading}`)).toBeInTheDocument()
    else expect(await screen.findByText('Fixture title')).toBeInTheDocument()
    expect(view.container.textContent).not.toMatch(/Upcoming events|Favorite events|Sign-in is temporarily unavailable|Account registration is temporarily unavailable|Please try connecting again\.|Other policies|Host your event with HåfaPass/)
    if (Component === PolicyPage) expect(await screen.findByText('English legal body')).toBeInTheDocument()
  })
})

it.each([
  [OrganizerPage, '/organizers/fixture', '/organizers/:slug', 'organizer'],
  [VenuePage, '/venues/fixture', '/venues/:slug', 'venue'],
  [CollectionPage, '/collections/fixture', '/collections/:slug', 'collection'],
])('translates the retry action when a public page fails', async (Component, route, path, namespace) => {
  api.get.mockRejectedValue(new Error('offline'))
  await renderPage(Component, route, path)
  expect(await screen.findByRole('button', { name: `TEST:buyerDiscovery.${namespace}.retry` })).toBeInTheDocument()
  expect(screen.queryByText('Retry')).not.toBeInTheDocument()
})
