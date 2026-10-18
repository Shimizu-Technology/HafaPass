import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { createInstance } from 'i18next'
import { I18nextProvider } from 'react-i18next'
import { expect, it, vi } from 'vitest'
import Footer from './Footer'
import HomePage from '../pages/HomePage'
import en from '../locales/en.json'
import ja from '../locales/ja.json'
import api from '../api/client'
vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))
vi.mock('./SEO', () => ({ default: () => null }))
it('uses the selected Japanese locale for recovery links and free/current-priced home inventory', async () => {
  const i18n = createInstance()
  await i18n.init({ lng: 'ja', fallbackLng: 'en', resources: { en: { translation: en }, ja: { translation: ja } }, interpolation: { escapeValue: false } })
  const make = (id, price) => ({ id, title: `Synthetic ${id}`, slug: `synthetic-${id}`, starts_at: '2099-10-20T07:00:00Z', timezone: 'Pacific/Guam', category: 'other', ticket_types: [{ price_cents: price, current_price_cents: price, quantity_remaining: 10, on_sale: true }] })
  api.get.mockResolvedValue({ data: { events: [make(1, 0), make(2, 1250)] } })
  render(<I18nextProvider i18n={i18n}><MemoryRouter><HomePage /></MemoryRouter></I18nextProvider>)
  expect(await screen.findByText('無料')).toBeInTheDocument()
  expect(screen.getByText('〜から $12.50')).toBeInTheDocument()
  expect(screen.getByRole('link', { name: 'チケットを探す' })).toHaveAttribute('href', '/orders/recover')
  expect(screen.getByRole('link', { name: 'サポートに連絡' }).getAttribute('href')).toMatch(/^mailto:/)
  expect(screen.getByRole('heading', { name: 'ヘルプ' })).toBeInTheDocument()
  expect(screen.queryByText('Free', { exact: true })).not.toBeInTheDocument()
  expect(screen.queryByText('Find your tickets')).not.toBeInTheDocument()
})
it('can localize the standalone footer independently of the home listing', async () => {
  const i18n = createInstance(); await i18n.init({ lng: 'ja', resources: { ja: { translation: ja } } })
  render(<I18nextProvider i18n={i18n}><MemoryRouter><Footer /></MemoryRouter></I18nextProvider>)
  expect(screen.getByRole('link', { name: 'チケットを探す' })).toHaveAttribute('href', '/orders/recover')
})
