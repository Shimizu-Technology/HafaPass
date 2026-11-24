import { expect, it } from 'vitest'
import axios from 'axios'
import { createDemoAdapter } from './demoApiAdapter'
import { DEMO_EMAIL_TOKEN, DEMO_EVENTS } from './demoFixtures'

it('keeps email preview changes local, persists toggles, and fails closed for unknown tokens', async () => {
  const api = axios.create({ adapter: createDemoAdapter() })
  expect((await api.post('/platform_subscriptions', { email: 'visitor@example.invalid' })).status).toBe(202)
  expect((await api.post(`/platform_subscriptions/confirm/${DEMO_EMAIL_TOKEN}`)).data.confirmed).toBe(true)
  const url = `/email_preferences/${DEMO_EMAIL_TOKEN}`
  const initial = (await api.get(url)).data
  const id = initial.organizers[0].id
  await api.patch(url, { platform: false, organizers: [{ id, enabled: false }] })
  expect((await api.get(url)).data).toMatchObject({ platform: false, organizers: [{ enabled: false }] })
  await api.patch(url, { platform: true, organizers: [{ id, enabled: true }] })
  await api.patch(url, { unsubscribe_all: true })
  expect((await api.get(url)).data).toMatchObject({ platform: false, organizers: [{ enabled: false }] })
  await expect(api.get('/email_preferences/invalid')).rejects.toMatchObject({ response: { status: 404 } })
  const organization_id = DEMO_EVENTS[0].organizer.id
  await api.post('/me/organizer_follows', { organization_id })
  expect((await api.get('/me/organizer_follows')).data.organizers[0].email_opt_in).toBe(false)
  await api.post('/me/organizer_follows', { organization_id, email_opt_in: true })
  expect((await api.get('/me/organizer_follows')).data.organizers[0].email_opt_in).toBe(true)
  await api.delete(`/me/organizer_follows/${organization_id}`)
  expect((await api.get('/me/organizer_follows')).data.organizers).toEqual([])
  await expect(api.post('/me/organizer_follows', { organization_id, email_opt_in: true, consent_only: true })).rejects.toMatchObject({ response: { status: 404 } })
  expect((await api.get('/me/organizer_follows')).data.organizers).toEqual([])
})
