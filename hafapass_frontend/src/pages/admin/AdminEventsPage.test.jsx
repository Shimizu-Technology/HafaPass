import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import apiClient from '../../api/client'
import AdminEventsPage from './AdminEventsPage'

vi.mock('../../api/client', async importOriginal => ({
  ...await importOriginal(),
  default: { get: vi.fn(), patch: vi.fn() },
}))

vi.mock('./AdminLayout', () => ({
  default: ({ children }) => <div>{children}</div>,
}))

vi.mock('../../components/PilotReadinessReviewDialog', () => ({ default: () => <button type="button">Prepare pilot readiness</button> }))
vi.mock('../../components/PilotValidationReviewDialog', () => ({ default: () => <button type="button">Prepare Gate F evidence</button> }))
vi.mock('../../components/EventDayRehearsalReviewDialog', () => ({ default: () => <button type="button">Prepare Gate G rehearsal</button> }))
vi.mock('../../components/LiveMoneyProofReviewDialog', () => ({ default: () => <button type="button">Prepare Gate H live-money proof</button> }))
vi.mock('../../components/LivePilotOperationsDialog', () => ({ default: () => <button type="button">Prepare Gate I bounded pilot</button> }))
vi.mock('../../components/PilotCloseoutDialog', () => ({ default: ({ onComplete }) => <button type="button" onClick={onComplete}>Prepare Gate J closeout</button> }))

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

    fireEvent.click(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' }))
    fireEvent.click(screen.getByRole('button', { name: 'Mark as hidden proof candidate' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Candidate cannot change after orders exist.')
    await waitFor(() => expect(apiClient.patch).toHaveBeenCalledWith('/admin/events/42', {
      live_money_proof_candidate: true,
    }, expect.objectContaining({ signal: expect.any(AbortSignal) })))
  })
  it('keeps the release gates open after a gate action refreshes the list', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' }))
    fireEvent.click(screen.getByRole('button', { name: 'Prepare Gate J closeout' }))

    await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
    expect(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByRole('button', { name: 'Prepare Gate J closeout' })).toBeInTheDocument()
  })
  it('keeps the row, panel and focused trigger mounted while a gate action refresh is pending', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)
    fireEvent.click(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' }))
    let finish
    apiClient.get.mockReturnValueOnce(new Promise(resolve => { finish = resolve }))
    const trigger = screen.getByRole('button', { name: 'Prepare Gate J closeout' })
    trigger.focus()
    fireEvent.click(trigger)

    await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Prepare Gate J closeout' })).toBe(trigger)
    expect(trigger).toHaveFocus()
    await act(async () => finish({ data: { events: [proofEvent], meta: { page: 1, total_pages: 1 } } }))
    expect(screen.getByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
  })
  it('collapses every release gate action behind one per-row control', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    const toggle = await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' })
    expect(toggle).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('button', { name: 'Prepare pilot readiness' })).not.toBeInTheDocument()
    expect(screen.getByRole('cell', { name: 'Draft' })).toBeInTheDocument()

    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-expanded', 'true')
    const actions = within(screen.getByRole('group', { name: 'Release gate actions for [LIVE MONEY TEST] Proof' }))
    for (const name of ['Prepare pilot readiness', 'Prepare Gate F evidence', 'Prepare Gate G rehearsal', 'Prepare Gate H live-money proof',
      'Prepare Gate I bounded pilot', 'Prepare Gate J closeout', 'Mark as hidden proof candidate']) {
      expect(actions.getByRole('button', { name })).toBeInTheDocument()
    }
  })

  it('keeps hiding Gate I and J actions for proof candidates', async () => {
    apiClient.get.mockResolvedValue({ data: { events: [{ ...proofEvent, live_money_proof_candidate: true }], meta: { page: 1, total_pages: 1 } } })
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' }))
    expect(screen.getByRole('button', { name: 'Prepare Gate H live-money proof' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Prepare Gate I bounded pilot' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Prepare Gate J closeout' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Remove proof-candidate flag' })).toBeInTheDocument()
  })

  it('closes expanded release gates when the listing filters change', async () => {
    render(<MemoryRouter initialEntries={['/admin/events']}><AdminEventsPage /></MemoryRouter>)

    fireEvent.click(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' }))
    expect(screen.getByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'true')
    fireEvent.change(screen.getByRole('combobox', { name: 'Filter events by status' }), { target: { value: 'draft' } })

    await waitFor(() => expect(apiClient.get).toHaveBeenLastCalledWith('/admin/events', expect.objectContaining({ params: expect.objectContaining({ status: 'draft' }) })))
    expect(await screen.findByRole('button', { name: 'Release gates for [LIVE MONEY TEST] Proof' })).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByRole('button', { name: 'Prepare Gate J closeout' })).not.toBeInTheDocument()
  })
})
