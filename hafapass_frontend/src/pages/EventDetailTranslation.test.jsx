import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import i18next from 'i18next'
import { I18nextProvider } from 'react-i18next'
import en from '../locales/en.json'
import EventDetailPage from './EventDetailPage'
import apiClient from '../api/client'
import { configureEnabledLanguages, setActiveLanguage } from '../utils/locale'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('@clerk/clerk-react', () => ({ useAuth: () => ({ isLoaded: true, userId: null }) }))
vi.mock('framer-motion', async original => ({ ...(await original()), useReducedMotion: () => true }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/ui/ScrollReveal', () => ({ FadeUp: ({ children }) => children }))
vi.mock('../utils/marketplaceAttribution', () => ({ captureQueryAttribution: vi.fn(), trackFunnel: vi.fn() }))

const english = {
  id: 7, slug: 'reef-night', title: 'Reef Night', description: 'Snorkel social', status: 'published', purchasable: true,
  timezone: 'Pacific/Guam', starts_at: '2099-10-20T08:00:00Z', attendee_count: 0, attendees_preview: [], machine_translated: false,
  ticket_types: [{ id: 1, name: 'General', original_name: 'General', price_cents: 1500, on_sale: true, quantity_remaining: 20 }],
}
const korean = {
  ...english, title: '리프 나이트', description: '스노클 모임', machine_translated: true, content_locale: 'ko',
  original_content: { title: 'Reef Night', description: 'Snorkel social' },
  ticket_types: [{ ...english.ticket_types[0], name: '일반', machine_translated: true, original_description: null }],
}

beforeEach(() => {
  vi.clearAllMocks()
  configureEnabledLanguages('ko')
  vi.stubGlobal('IntersectionObserver', class { observe() {} disconnect() {} })
})
afterEach(() => { configureEnabledLanguages('en'); setActiveLanguage('en'); vi.unstubAllGlobals() })

async function mount() {
  const i18n = i18next.createInstance()
  await i18n.init({ lng: 'en', fallbackLng: 'en', supportedLngs: ['en', 'ko'], resources: { en: { translation: en }, ko: { translation: en } } })
  apiClient.get.mockImplementation(() => Promise.resolve({ data: i18n.language === 'ko' ? korean : english }))
  render(<I18nextProvider i18n={i18n}><MemoryRouter initialEntries={['/events/reef-night']}><Routes>
    <Route path="/events/:slug" element={<EventDetailPage />} />
  </Routes></MemoryRouter></I18nextProvider>)
  await screen.findByRole('heading', { name: 'Reef Night' })
  return i18n
}

it('reloads the event text when the language changes and offers the original', async () => {
  const i18n = await mount()
  expect(apiClient.get).toHaveBeenCalledTimes(1)
  expect(screen.queryByRole('button', { name: 'Show original' })).not.toBeInTheDocument()

  await act(async () => { await i18n.changeLanguage('ko') })

  expect(await screen.findByRole('heading', { name: '리프 나이트' })).toBeInTheDocument()
  expect(apiClient.get).toHaveBeenCalledTimes(2)
  expect(screen.getByText('스노클 모임')).toBeInTheDocument()
  expect(screen.getByRole('heading', { name: '일반' })).toBeInTheDocument()

  await userEvent.setup().click(screen.getByRole('button', { name: 'Show original' }))
  expect(screen.getByRole('heading', { name: 'Reef Night' })).toBeInTheDocument()
  expect(screen.getByText('Snorkel social')).toBeInTheDocument()
  expect(screen.getByRole('heading', { name: 'General' })).toBeInTheDocument()
  await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
  expect(within(document.body).getByRole('button', { name: 'Show translation' })).toHaveAttribute('aria-pressed', 'true')
})
