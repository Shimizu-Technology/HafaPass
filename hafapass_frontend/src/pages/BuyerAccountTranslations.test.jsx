import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { I18nextProvider } from 'react-i18next'
import i18next from 'i18next'
import en from '../locales/en.json'
import apiClient from '../api/client'
import OrderConfirmationPage from './OrderConfirmationPage'
import TicketPage from './TicketPage'
import MyTicketsPage from './MyTicketsPage'
import OrderRecoveryPage from './OrderRecoveryPage'
import TicketTransferAcceptPage from './TicketTransferAcceptPage'
import TransferTicketDialog from '../components/TransferTicketDialog'
import PendingTransfer from '../components/PendingTransfer'

vi.mock('../api/client', async original => ({ ...await original(), default: { get: vi.fn(), post: vi.fn(), delete: vi.fn() } }))
vi.mock('../hooks/useLaunchCapabilities', () => ({ default: () => ({ ticket_transfers: true }) }))
vi.mock('../components/ui/ScrollReveal', () => ({ StaggerContainer: ({ children }) => <div>{children}</div>, StaggerItem: ({ children }) => <div>{children}</div> }))
vi.mock('../components/SEO', () => ({ default: () => null }))
vi.mock('../components/QRCode', () => ({ default: () => <div data-testid="qr" /> }))

// Every source leaf gets a distinct fake translation, retaining placeholders
// and formatting tags. A missing extraction therefore renders English visibly.
function fakeResources(source, path = '') {
  return Object.fromEntries(Object.entries(source).map(([key, value]) => {
    const full = path ? `${path}.${key}` : key
    return [key, typeof value === 'object' ? fakeResources(value, full)
      : `XX:${full} ${(value.match(/<\/?[a-z]+>|\{\{[^}]+\}\}/gi) || []).join('')}`.trim()]
  }))
}

const translated = key => `XX:${key}`
const event = {
  id: 1, title: '翻訳されたイベント', slug: 'synthetic-event', status: 'published',
  starts_at: '2030-01-01T08:00:00Z', timezone: 'Pacific/Guam', venue_name: '会場',
  machine_translated: true, original_content: { title: 'Organizer original event' },
}
const ticket = {
  id: 3, order_id: 2, status: 'issued', admission_allowed: true, refundable_cents: 0,
  display_credential: 'synthetic-display', scan_credential: 'synthetic-entry',
  ticket_type: { name: '入場券' }, event,
}
const order = {
  id: 2, reference: 'HP-2', status: 'completed', buyer_email: 'buyer@example.invalid',
  order_items: [], total_cents: 0, tickets: [ticket], event,
}

async function mount(component, route = '/', initial = route) {
  const i18n = i18next.createInstance()
  await i18n.init({ lng: 'xx', fallbackLng: 'en', resources: { en: { translation: en }, xx: { translation: fakeResources(en) } }, interpolation: { escapeValue: false }, react: { useSuspense: false } })
  const view = render(<I18nextProvider i18n={i18n}><MemoryRouter initialEntries={[initial]}><Routes>
    <Route path={route} element={component} />
  </Routes></MemoryRouter></I18nextProvider>)
  return { ...view, i18n }
}

beforeEach(() => {
  vi.clearAllMocks()
  vi.stubEnv('VITE_CLERK_PUBLISHABLE_KEY', '')
  window.localStorage.clear()
  window.sessionStorage.clear()
  apiClient.post.mockResolvedValue({ data: {} })
})

afterEach(() => vi.unstubAllEnvs())

describe('buyer account pages in another language', () => {
  it.each([
    ['order confirmation', <OrderConfirmationPage />, '/orders/:id/confirmation', '/orders/2/confirmation', 'buyerAccount.orderConfirmationPage.yourOrderIsConfirmed'],
    ['ticket', <TicketPage />, '/tickets/:credential', '/tickets/synthetic-display', 'buyerAccount.ticketPage.downloadPDF'],
    ['my tickets', <MyTicketsPage />, '/my-tickets', '/my-tickets', 'buyerAccount.myTicketsPage.myTickets'],
  ])('extracts %s chrome and lets the buyer inspect original event wording', async (name, page, route, initial, key) => {
    apiClient.get.mockResolvedValue({ data: name === 'order confirmation' ? order : name === 'ticket' ? ticket : { tickets: [ticket] } })
    await mount(page, route, initial)
    await screen.findByText(translated(key), { exact: false })
    expect(screen.queryByText('Your order is confirmed')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Download PDF' })).not.toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'My Tickets' })).not.toBeInTheDocument()
    expect(screen.getByText(event.title)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: translated('translation.showOriginal') }))
    expect(screen.getByText('Organizer original event')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: translated('translation.showTranslation') }))
    expect(screen.getByText(event.title)).toBeInTheDocument()
  })

  it('extracts order recovery labels, placeholders and success copy', async () => {
    await mount(<OrderRecoveryPage />)
    expect(screen.getByRole('heading', { name: translated('buyerAccount.orderRecoveryPage.findYourOrder2') })).toBeInTheDocument()
    expect(screen.queryByText('Enter the reference from your receipt and the email used at checkout.')).not.toBeInTheDocument()
    await userEvent.type(screen.getByLabelText(translated('buyerAccount.orderRecoveryPage.orderReference')), 'HP-2')
    await userEvent.type(screen.getByLabelText(translated('buyerAccount.orderRecoveryPage.emailAddress')), 'buyer@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: translated('buyerAccount.orderRecoveryPage.emailSecureLink') }))
    expect(await screen.findByRole('heading', { name: translated('buyerAccount.orderRecoveryPage.checkYourEmail') })).toBeInTheDocument()
  })

  it('extracts transfer acceptance and does not accept again when the language changes', async () => {
    const { i18n } = await mount(<TicketTransferAcceptPage />, '/accept', '/accept?token=synthetic')
    expect(await screen.findByRole('heading', { name: translated('buyerAccount.ticketTransferAcceptPage.ticketAccepted') })).toBeInTheDocument()
    expect(screen.queryByText('View my tickets')).not.toBeInTheDocument()
    await act(() => i18n.changeLanguage('en'))
    await waitFor(() => expect(screen.getByRole('heading', { name: 'Ticket accepted' })).toBeInTheDocument())
    expect(apiClient.post).toHaveBeenCalledTimes(1)
  })

  it('extracts the send transfer form and the complete interpolated confirmation', async () => {
    await mount(<TransferTicketDialog ticketLabel="入場券" onSend={vi.fn().mockResolvedValue({})} onClose={vi.fn()} />)
    expect(screen.queryByText('Recipient email')).not.toBeInTheDocument()
    await userEvent.type(screen.getByLabelText(translated('buyerAccount.transferTicketDialog.recipientEmail')), 'friend@example.invalid')
    await userEvent.click(screen.getByRole('button', { name: translated('buyerAccount.transferTicketDialog.sendTransfer') }))
    expect(await screen.findByRole('heading', { name: translated('buyerAccount.transferTicketDialog.transferSent') })).toBeInTheDocument()
    expect(screen.getByText('friend@example.invalid').tagName).toBe('STRONG')
    expect(screen.queryByText('Done')).not.toBeInTheDocument()
  })

  it('extracts the pending transfer and cancellation dialog', async () => {
    await mount(<PendingTransfer transfer={{ id: 1, recipient_email: 'friend@example.invalid', expires_at: '2030-01-01T08:00:00Z' }} onCancel={vi.fn()} />)
    expect(screen.queryByText('Transfer pending')).not.toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: translated('buyerAccount.pendingTransfer.cancelTransfer') }))
    expect(screen.getByRole('heading', { name: translated('buyerAccount.pendingTransfer.cancelThisTransfer') })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Keep transfer' })).not.toBeInTheDocument()
  })
})
