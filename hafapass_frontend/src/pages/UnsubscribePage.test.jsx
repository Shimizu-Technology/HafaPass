import { beforeEach, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../api/client'
import UnsubscribePage from './UnsubscribePage'
import { createInstance } from 'i18next'
import { I18nextProvider } from 'react-i18next'
import en from '../locales/en.json'
import ja from '../locales/ja.json'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { organization: 'Island Nights', unsubscribed: false } })
})

it('uses GET for confirmation and POST for unsubscribe, without an old-link resubscribe action', async () => {
  const user = userEvent.setup()
  apiClient.post.mockResolvedValue({ data: { unsubscribed: true } })
  render(<MemoryRouter initialEntries={['/unsubscribe/signed-token']}><Routes><Route path="/unsubscribe/:token" element={<UnsubscribePage />} /></Routes></MemoryRouter>)
  expect(await screen.findByText(/Unsubscribe from promotional emails from Island Nights/)).toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
  await user.click(screen.getByRole('button', { name: 'Unsubscribe' }))
  expect(apiClient.post).toHaveBeenCalledWith('/marketing/unsubscribe/signed-token', {})
  expect(await screen.findByText(/To get updates again, opt in at your next checkout/)).toBeInTheDocument()
  expect(screen.queryByText(/or in your account/)).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Resubscribe' })).not.toBeInTheDocument()
})

it('shows the confirmation and action in the buyer language', async () => {
  const i18n = createInstance()
  await i18n.init({ lng: 'ja', fallbackLng: 'en', resources: { en: { translation: en }, ja: { translation: ja } },
    interpolation: { escapeValue: false } })
  render(<I18nextProvider i18n={i18n}><MemoryRouter initialEntries={['/unsubscribe/signed-token']}><Routes>
    <Route path="/unsubscribe/:token" element={<UnsubscribePage />} />
  </Routes></MemoryRouter></I18nextProvider>)
  expect(await screen.findByText(ja.unsubscribe.heading)).toBeInTheDocument()
  expect(screen.getByText(ja.unsubscribe.prompt.replace('{{organization}}', 'Island Nights'))).toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: ja.unsubscribe.action }))
  expect(await screen.findByText(ja.unsubscribe.unsubscribedConfirmation.replace('{{organization}}', 'Island Nights'))).toBeInTheDocument()
})

it('offers event and organizer choices for a waitlist link', async () => {
  apiClient.get.mockResolvedValue({ data: { organization: 'Island Nights', event: 'Friday Show', scope: 'waitlist', unsubscribed: false } })
  apiClient.post.mockResolvedValue({ data: { unsubscribed: true } })
  render(<MemoryRouter initialEntries={['/unsubscribe/waitlist-token']}><Routes><Route path="/unsubscribe/:token" element={<UnsubscribePage />} /></Routes></MemoryRouter>)
  expect(await screen.findByRole('button', { name: 'Stop alerts for this event' })).toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Stop all marketing from this organizer' })).toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: 'Stop alerts for this event' }))
  expect(apiClient.post).toHaveBeenCalledWith('/marketing/unsubscribe/waitlist-token', { scope: 'event' })
  expect(await screen.findByText('Alerts for Friday Show have stopped.')).toBeInTheDocument()
  await userEvent.click(screen.getByRole('button', { name: 'Stop all marketing from this organizer' }))
  expect(apiClient.post).toHaveBeenCalledWith('/marketing/unsubscribe/waitlist-token', { scope: 'organizer' })
  expect(await screen.findByText('All marketing from Island Nights has stopped.')).toBeInTheDocument()
})
