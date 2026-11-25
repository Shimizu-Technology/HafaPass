import { afterEach, expect, it } from 'vitest'
import { handle } from './email-campaigns'

const call = (method, path, { params = {}, body = {}, state } = {}) => handle({ method, path, params: new URLSearchParams(params), body, state })

afterEach(() => window.history.replaceState(null, '', '/'))

it('serves the whole platform flow from fictional data and keeps changes in memory', async () => {
  const state = {}
  const audience = (await call('get', '/audience_mailings/audience', { params: { scope: 'platform' }, state })).data
  expect(audience).toMatchObject({ eligible: 312, considered: 336, status_breakdown: { confirmed: 314, pending: 9 } })
  expect(audience.subscribers.every(row => row.email.endsWith('@example.test'))).toBe(true)
  const history = (await call('get', '/audience_mailings', { params: { scope: 'platform' }, state })).data.mailings
  expect(history.map(row => row.status)).toEqual(expect.arrayContaining(['draft', 'queued', 'scheduled', 'blocked', 'cancelled']))

  const draft = (await call('post', '/audience_mailings', { body: { scope: 'platform', subject: 'Hello', body: 'Body' }, state })).data
  expect((await call('post', `/audience_mailings/${draft.id}/test_send`, { body: { scope: 'platform' }, state })).data.recipient).toMatch(/@example\.invalid$/)
  const sent = (await call('post', `/audience_mailings/${draft.id}/send_now`, { body: { scope: 'platform', scheduled_at: null }, state })).data
  expect(sent).toMatchObject({ status: 'queued', recipient_count: 312, disposition: 'sending_now' })
  expect((await call('post', `/audience_mailings/${draft.id}/send_now`, { body: { scope: 'platform' }, state })).status).toBe(409)

  const later = (await call('post', '/audience_mailings', { body: { scope: 'platform', subject: 'Later', body: 'Body' }, state })).data
  const when = new Date(Date.now() + 3_600_000).toISOString()
  expect((await call('post', `/audience_mailings/${later.id}/send_now`, { body: { scope: 'platform', scheduled_at: when }, state })).data)
    .toMatchObject({ status: 'scheduled', scheduled_at: when, disposition: 'scheduled_for' })
  const soon = (await call('post', '/audience_mailings', { body: { scope: 'platform', subject: 'Soon', body: 'Body' }, state })).data
  const refused = await call('post', `/audience_mailings/${soon.id}/send_now`, { body: { scope: 'platform', scheduled_at: new Date(Date.now() + 20_000).toISOString() }, state })
  expect(refused).toMatchObject({ status: 422, data: { code: 'schedule_lapsed' } })
  expect(await call('get', '/organizer/events', { state })).toBeUndefined()
})

it('loads worst-case, empty and organizer data', async () => {
  window.history.replaceState(null, '', '/dashboard/email?demo_email=worst')
  const state = {}
  const history = (await call('get', '/audience_mailings', { params: { scope: 'platform' }, state })).data.mailings
  expect(history).toHaveLength(100)
  expect(history.find(row => row.id === 500)).toMatchObject({ status: 'queueing', recipient_count: 48000 })
  expect(history.find(row => row.id === 506)).toMatchObject({ status: 'scheduled' })
  expect(Date.parse(history.find(row => row.id === 506).scheduled_at)).toBeLessThan(Date.now())
  expect(history.find(row => row.id === 507)).toMatchObject({ status: 'queued', counts: { suppressed: 48, failed: 2 } })
  expect((await call('get', '/audience_mailings/audience', { params: { scope: 'platform' }, state })).data.eligible).toBe(48000)
  expect((await call('get', '/audience_mailings/audience', { params: { audience: 'waitlists' }, state })).data).toMatchObject({ eligible: 0, considered: 37 })

  window.history.replaceState(null, '', '/dashboard/email?demo_email=empty')
  expect((await call('get', '/audience_mailings/audience', { params: { scope: 'platform' }, state })).data).toMatchObject({ eligible: 0, considered: 0 })
  expect((await call('get', '/audience_mailings', { params: { scope: 'platform' }, state })).data.mailings).toEqual([])
})
