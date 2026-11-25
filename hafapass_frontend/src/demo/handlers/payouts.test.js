import { afterEach, describe, expect, it, vi } from 'vitest'

async function demoClient() {
  vi.resetModules()
  vi.stubEnv('VITE_HAFAPASS_DEMO_DATA', '1')
  vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Network must not be called in demo mode'))
  return (await import('../../api/client')).default
}

describe('demo payout statements and Due list', () => {
  afterEach(() => { vi.unstubAllEnvs(); vi.resetModules(); vi.restoreAllMocks() })

  it('shows every statement state on fictional demo events', async () => {
    const api = await demoClient()
    const finances = (await api.get('/organizer/finances')).data
    const demoRows = finances.events.filter(row => String(row.id).startsWith('93'))
    expect(demoRows.map(row => row.title).every(title => title.endsWith('(demo)'))).toBe(true)
    const labels = []
    for (const id of [101, ...demoRows.map(row => row.id)]) {
      const statement = (await api.get(`/organizer/events/${id}/finance/payout_statement`)).data
      expect(statement.organization.name).toBe('Isla Demo Sports League')
      expect(statement.reconciles).toBe(true)
      labels.push(statement.status)
    }
    expect(labels).toEqual(['sales_open', 'waiting_for_payout', 'reserve_held', 'final', 'final'])
    const paid = finances.payouts.find(item => item.event_id === 9312)
    const receipt = (await api.get('/organizer/events/9312/finance/payout_statement', { params: { payout_id: paid.id } })).data
    expect(receipt.payout).toMatchObject({ id: paid.id, bank_last4: '4321' })
    expect((await api.get('/organizer/events/9312/finance')).data.payouts.length).toBe(1)
  })

  it('walks the admin Due list through reserve, finalize, payout and release in memory', async () => {
    const api = await demoClient()
    let due = (await api.get('/admin/payout_schedule')).data
    expect(due.counts).toMatchObject({ overdue: 1, due: 2 })
    const first = due.transfers.find(row => row.event.id === 9311)
    expect(first.next_step).toBe('hold_reserve')
    await api.post(`/admin/payout_schedule/${first.event.id}/reserve`, {})
    await expect(api.post(`/admin/payout_schedule/${first.event.id}/reserve`, {})).rejects.toMatchObject({ response: { status: 422 } })
    const settlement = (await api.post(`/admin/payout_schedule/${first.event.id}/finalize`, {})).data
    expect(settlement.available_to_payout_cents).toBe(first.owed_cents - first.suggested_reserve_cents)
    await api.post('/admin/payouts', { settlement_id: settlement.id })
    due = (await api.get('/admin/payout_schedule')).data
    expect(due.transfers.find(row => row.event.id === 9311).next_step).toBe('record_transfer')
    const reserve = due.reserves[0]
    await api.post(`/admin/payout_schedule/${reserve.event.id}/release`, {})
    due = (await api.get('/admin/payout_schedule')).data
    expect(due.reserves).toEqual([])
    expect(due.transfers.find(row => row.event.id === reserve.event.id)).toMatchObject({ next_step: 'finalize_statement', owed_cents: reserve.after_release_cents })
    expect((await api.get('/admin/payout_schedule', { params: { filter: 'due_now' } })).data.transfers.every(row => ['due', 'overdue'].includes(row.due_state))).toBe(true)
  })
})
