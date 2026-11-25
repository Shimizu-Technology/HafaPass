import { afterEach, describe, expect, it } from 'vitest'
import { handle } from './box-office-print'
import { createDemoStaffState } from '../staff/fixtures'

const STORAGE_KEY = 'hafapass-demo:box-office-receipts'

function sell(state, event) {
  const type = event.ticket_types[0]
  return handle({
    method: 'post',
    path: `/organizer/events/${event.id}/box_office`,
    body: { payment_method: 'door_cash', line_items: [{ ticket_type_id: type.id, quantity: 2 }] },
    state,
    config: { headers: new Map() },
  })
}

const get = (state, eventId, orderId) => handle({
  method: 'get', path: `/organizer/events/${eventId}/box_office/orders/${orderId}`, body: {}, state, config: {},
})

describe('box office print demo handler', () => {
  afterEach(() => window.sessionStorage.clear())

  it('finds a completed sale again after a reload resets the in-memory demo state', async () => {
    const before = createDemoStaffState()
    const event = before.staff.events.find(item => item.ticket_types?.length)
    const sale = await sell(before, event)
    expect(sale.status).toBe(201)

    const afterReload = createDemoStaffState()
    const restored = await get(afterReload, event.id, sale.data.id)
    expect(restored.status).toBe(200)
    expect(restored.data.reference).toBe(sale.data.receipt.reference)
    expect(restored.data.admissions).toHaveLength(2)
  })

  it('keeps the email status after a reload', async () => {
    const state = createDemoStaffState()
    const event = state.staff.events.find(item => item.ticket_types?.length)
    const sale = await sell(state, event)
    await handle({
      method: 'post', path: `/organizer/events/${event.id}/box_office/orders/${sale.data.id}/email`,
      body: { email: 'someone@example.invalid' }, state, config: {},
    })
    const restored = await get(createDemoStaffState(), event.id, sale.data.id)
    expect(restored.data.email_status).toBe('queued')
  })

  it('still answers in memory when session storage is unusable', async () => {
    window.sessionStorage.setItem(STORAGE_KEY, 'not json')
    const state = createDemoStaffState()
    const event = state.staff.events.find(item => item.ticket_types?.length)
    const sale = await sell(state, event)
    expect((await get(state, event.id, sale.data.id)).status).toBe(200)
  })

  it('returns not found for an unknown order', async () => {
    const state = createDemoStaffState()
    const event = state.staff.events.find(item => item.ticket_types?.length)
    expect((await get(state, event.id, 999999)).status).toBe(404)
  })
})
