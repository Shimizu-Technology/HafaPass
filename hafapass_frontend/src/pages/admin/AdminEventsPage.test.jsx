import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import AdminEventsPage from './AdminEventsPage'

vi.mock('../../api/client', async importOriginal => ({
  ...await importOriginal(),
  default: { get: vi.fn(), patch: vi.fn(), post: vi.fn(), delete: vi.fn() },
}))

vi.mock('./AdminLayout', () => ({
  default: ({ children }) => <div>{children}</div>,
}))

vi.mock('../../components/PilotReadinessReviewDialog', () => ({ default: () => <button type="button">Prepare pilot readiness</button> }))
vi.mock('../../components/PilotValidationReviewDialog', () => ({ default: () => <button type="button">Prepare Gate F evidence</button> }))
vi.mock('../../components/EventDayRehearsalReviewDialog', () => ({ default: () => <button type="button">Prepare Gate G rehearsal</button> }))
vi.mock('../../components/LiveMoneyProofReviewDialog', () => ({ default: () => <button type="button">Prepare live-payment validation</button> }))
vi.mock('../../components/LivePilotOperationsDialog', () => ({ default: () => <button type="button">Prepare a limited live pilot</button> }))
vi.mock('../../components/PilotCloseoutDialog', () => ({ default: ({ onComplete }) => <button type="button" onClick={onComplete}>Prepare pilot closeout</button> }))

const proofEvent = {
  id: 42,
  slug: 'live-proof',
  title: '[LIVE MONEY TEST] Proof',
  organizer_name: 'HafaPass Finance',
  status: 'draft',
  category: 'other',
  tickets_sold: 0,
  revenue_cents: 0,
  is_featured: false,
  live_money_proof_candidate: false,
}

describe('AdminEventsPage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    apiClient.get.mockResolvedValue({ data: { events: [proofEvent], meta: { page: 1, total_pages: 1 } } })
  })

  it('shows the server rejection when the proof-candidate flag cannot change', async () => {
    apiClient.patch.mockRejectedValue({ response: { data: { errors: ['Candidate cannot change after orders exist.'] } } })
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' }))
    fireEvent.click(screen.getByRole('button', { name: 'Mark as hidden proof candidate' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Candidate cannot change after orders exist.')
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/events/42', {
      live_money_proof_candidate: true,
    }, expect.objectContaining({ signal: expect.any(AbortSignal) })))
  })
  it('keeps the release gates open after a gate action refreshes the list', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' }))
    fireEvent.click(screen.getByRole('button', { name: 'Prepare pilot closeout' }))

    await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
    expect(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('button', { name: 'Prepare pilot closeout' })).toBeInTheDocument()
  })
  it('keeps the row, panel and focused trigger mounted while a gate action refresh is pending', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)
    fireEvent.click(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' }))
    let finish
    apiClient.get.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const trigger = screen.getByRole('button', { name: 'Prepare pilot closeout' })
    trigger.focus()
    fireEvent.click(trigger)

    await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Prepare pilot closeout' })).toBe(trigger)
    expect(trigger).toHaveFocus()
    await act(async () => finish({ data: { events: [proofEvent], meta: { page: 1, total_pages: 1 } } }))
    expect(screen.getByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
  })
  it('keeps the rows and focused trigger when the post-action refresh fails, with a retry', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)
    fireEvent.click(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' }))
    apiClient.get.mockRejectedValueOnce(new Error('network down'))
    const trigger = screen.getByRole('button', { name: 'Prepare pilot closeout' })
    trigger.focus()
    fireEvent.click(trigger)

    expect(await screen.findByRole('alert')).toHaveTextContent('Could not refresh events after that action.')
    expect(screen.getByRole('button', { name: 'Prepare pilot closeout' })).toBe(trigger)
    expect(trigger).toHaveFocus()
    fireEvent.click(screen.getByRole('button', { name: 'Refresh list' }))
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
    expect(screen.getByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
  })
  it('collapses every release gate action behind one per-row control', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    const toggle = await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('button', { name: 'Prepare pilot readiness' })).not.toBeInTheDocument()
    expect(screen.getByRole('cell', { name: 'Draft' })).toBeInTheDocument()

    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    const actions = within(screen.getByRole('group', { name: 'Launch review actions for [LIVE MONEY TEST] Proof' }))
    for (const name of ['Prepare pilot readiness', 'Prepare Gate F evidence', 'Prepare Gate G rehearsal', 'Prepare live-payment validation',
      'Prepare a limited live pilot', 'Prepare pilot closeout', 'Mark as hidden proof candidate']) {
      expect(actions.getByRole('button', { name })).toBeInTheDocument()
    }
  })

  it('keeps hiding Gate I and J actions for proof candidates', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [{ ...proofEvent, live_money_proof_candidate: true }], meta: { page: 1, total_pages: 1 } } })
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' }))
    expect(screen.getByRole('button', { name: 'Prepare live-payment validation' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Prepare a limited live pilot' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Prepare pilot closeout' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Remove proof-candidate flag' })).toBeInTheDocument()
  })

  it('closes expanded release gates when the listing filters change', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' }))
    expect(screen.getByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
    fireEvent.change(screen.getByRole('combobox', { name: 'Filter events by status' }), { target: { value: 'draft' } })

    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/events', expect.objectContaining({ params: expect.objectContaining({ status: 'draft' }) })))
    expect(await screen.findByRole('button', { name: 'Launch reviews for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('button', { name: 'Prepare pilot closeout' })).not.toBeInTheDocument()
  })

  it('pauses sales with a required reason, then shows the hold and links to the event payouts', async () => {
    const published = { ...proofEvent, id: 7, title: 'Night Market', status: 'published', policy_hold: null }
    apiClient.get.mockResolvedValue({ data: { events: [published], meta: { page: 1, total_pages: 1 } } })
    apiClient.post.mockResolvedValue({ data: {} })
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    expect(await screen.findByRole('link', { name: 'Payouts for Night Market' })).toHaveAttribute('href', '/admin/payouts?event_id=7')
    fireEvent.click(screen.getByRole('button', { name: 'Pause or hide Night Market' }))
    const dialog = screen.getByRole('dialog', { name: 'Policy hold for Night Market' })
    expect(dialog).toHaveTextContent('Nothing is deleted, cancelled or refunded.')
    fireEvent.click(within(dialog).getByRole('button', { name: 'Pause sales' }))
    expect(within(dialog).getByRole('alert')).toHaveTextContent('The organizer will see it.')
    expect(apiClient.post).not.toHaveBeenCalled()

    fireEvent.click(within(dialog).getByRole('radio', { name: /Hide the event/ }))
    fireEvent.change(within(dialog).getByLabelText('Policy reason (shown to the organizer)'), { target: { value: 'Counterfeit listing' } })
    apiClient.get.mockResolvedValue({ data: { events: [{ ...published, policy_hold: { scope: 'hidden', reason: 'Counterfeit listing', placed_at: '2026-10-20T00:00:00Z' } }], meta: { page: 1, total_pages: 1 } } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Hide the event' }))

    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/admin/events/7/policy_hold', { scope: 'hidden', reason: 'Counterfeit listing' }, expect.anything()))
    expect(await screen.findByText('Hidden by HåfaPass')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Night Market is hidden and its sales are paused.')
    expect(screen.getByRole('button', { name: 'Restore Night Market' })).toBeInTheDocument()
  })

  it('restores a held event with a reason', async () => {
    const held = { ...proofEvent, id: 7, title: 'Night Market', status: 'published', policy_hold: { scope: 'sales', reason: 'Prohibited items', placed_at: '2026-10-20T00:00:00Z', placed_by: 'admin@example.com' } }
    apiClient.get.mockResolvedValue({ data: { events: [held], meta: { page: 1, total_pages: 1 } } })
    apiClient.delete.mockResolvedValue({ data: {} })
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    expect(await screen.findByText('Sales paused by HåfaPass')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Restore Night Market' }))
    const dialog = screen.getByRole('dialog', { name: 'Restore Night Market?' })
    expect(dialog).toHaveTextContent('Prohibited items')
    fireEvent.change(within(dialog).getByLabelText('Why can it be restored?'), { target: { value: 'Items removed' } })
    fireEvent.click(within(dialog).getByRole('button', { name: 'Restore event' }))
    await waitFor(() => expect(apiClient.delete).toHaveBeenCalledWith('/admin/events/7/policy_hold', expect.objectContaining({ data: { reason: 'Items removed' } })))
  })

  it('filters to events on a policy hold', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)
    fireEvent.click(await screen.findByRole('checkbox', { name: 'On policy hold' }))
    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/events', expect.objectContaining({ params: expect.objectContaining({ policy_hold: 'true' }) })))
  })

  it('shows why HåfaPass paused sales and resumes them with an optional note', async () => {
    const suspended = { ...proofEvent, id: 8, title: 'Reef Fest', status: 'published', sales_suspended: true, sales_suspension_reason: 'Chargeback review.' }
    apiClient.get.mockResolvedValueOnce({ data: { events: [suspended], meta: { page: 1, total_pages: 1 } } })
      .mockResolvedValue({ data: { events: [{ ...suspended, sales_suspended: false, sales_suspension_reason: null }], meta: { page: 1, total_pages: 1 } } })
    apiClient.delete.mockResolvedValue({ data: { id: 8, sales_suspended: false, sales_status: { on_sale: true } } })
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)
    expect((await screen.findAllByText('Chargeback review.')).length).toBeGreaterThan(0)
    fireEvent.click(screen.getByRole('button', { name: 'Resume sales for Reef Fest' }))
    const dialog = within(screen.getByRole('dialog', { name: 'Resume sales for Reef Fest?' }))
    fireEvent.change(dialog.getByRole('textbox', { name: /Note/ }), { target: { value: 'Resolved with the bank.' } })
    fireEvent.click(dialog.getByRole('button', { name: 'Resume sales' }))
    await waitFor(() => expect(apiClient.delete).toHaveBeenCalledWith('/admin/events/8/sales_suspension', expect.objectContaining({ data: { note: 'Resolved with the bank.' } })))
    expect(await screen.findByText('Sales resumed for Reef Fest.')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Resume sales for Reef Fest' })).not.toBeInTheDocument())
  })
})
