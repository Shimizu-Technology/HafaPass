import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { vi, it, expect, afterEach } from 'vitest'
import AudienceMailingsPage from './AudienceMailingsPage'
import apiClient from '../api/client'
import en from '../locales/en.json'
const state = vi.hoisted(() => ({ identity: { ready: true, accountKey: 'admin', organizationId: null, authContext: null }, t: (key, values = {}) => {
  const text = key.split('.').reduce((value, part) => value?.[part], en)
  if (['emailBase.confirmSend', 'emailBase.platform', 'emailBase.now', 'emailBase.atTime'].includes(key)) return text.replace(/{{(\w+)}}/g, (_, name) => values[name])
  return key
} }))
vi.mock('../hooks/useOrganizerContext', () => ({ useOrganizerIdentity: () => state.identity }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: state.t }) }))
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
it('previews desktop/mobile HTML, self-tests, then sends only the saved draft', async () => {
  vi.spyOn(window, 'confirm').mockReturnValue(true)
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? { eligible: 1, count: 1, subscribers: [{ email: 'alerts@example.test' }] } : { mailings: [] } }))
  apiClient.post.mockImplementation(path => Promise.resolve({ data: path.endsWith('/preview') ? { html: '<p>Exact rendered email</p>', eligible: 1 } : { id: 17 } }))
  render(<MemoryRouter initialEntries={['/dashboard/email?scope=platform']}><AudienceMailingsPage /></MemoryRouter>)
  expect(await screen.findByText('alerts@example.test')).toBeInTheDocument()
  fireEvent.change(screen.getByLabelText('emailBase.subject'), { target: { value: 'Events' } })
  fireEvent.change(screen.getByLabelText('emailBase.body'), { target: { value: 'On Guam' } })
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.preview' }))
  expect(await screen.findByTitle('emailBase.preview 600')).toHaveAttribute('srcdoc', '<p>Exact rendered email</p>')
  expect(screen.getByTitle('emailBase.preview 375')).toHaveAttribute('sandbox', '')
  expect(screen.getByRole('button', { name: 'emailBase.send' })).toBeDisabled()
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.test' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/test_send', { scope: 'platform' }, { organizationId: null }))
  await waitFor(() => expect(screen.getByRole('button', { name: 'emailBase.send' })).not.toBeDisabled())
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.send' }))
  expect(window.confirm).toHaveBeenCalledWith('Send "Events" to 1 recipients in Platform event alerts now?')
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/send_now', { scope: 'platform', scheduled_at: null }, { organizationId: null }))
})
it('ignores superseded search results', async () => {
  let finishOld
  apiClient.get.mockImplementation((path, config) => {
    if (!path.endsWith('/audience')) return Promise.resolve({ data: { mailings: [] } })
    if (config.params.q === 'alice') return new Promise(resolve => { finishOld = resolve })
    return Promise.resolve({ data: { eligible: 1, count: 1, subscribers: [{ email: config.params.q || 'initial' }] } })
  })
  render(<MemoryRouter initialEntries={['/dashboard/email?scope=platform']}><AudienceMailingsPage /></MemoryRouter>)
  await screen.findByText('initial')
  fireEvent.change(screen.getByLabelText('emailBase.search'), { target: { value: 'alice' } })
  await waitFor(() => expect(finishOld).toBeTypeOf('function'))
  fireEvent.change(screen.getByLabelText('emailBase.search'), { target: { value: 'bob' } })
  await screen.findByText('bob')
  finishOld({ data: { eligible: 1, count: 1, subscribers: [{ email: 'alice' }] } })
  await waitFor(() => expect(screen.queryByText('alice')).not.toBeInTheDocument())
})
it('locks composition while creating a draft and requires a successful test', async () => {
  let finishCreate
  apiClient.get.mockResolvedValue({ data: { eligible: 1, count: 1, subscribers: [], mailings: [] } })
  apiClient.post.mockImplementation(path => path.endsWith('/preview') ? Promise.resolve({ data: { html: '<p>Preview</p>', eligible: 1 } }) : path === '/audience_mailings' ? new Promise(resolve => { finishCreate = resolve }) : Promise.reject(new Error('test failed')))
  render(<MemoryRouter initialEntries={['/dashboard/email?scope=platform']}><AudienceMailingsPage /></MemoryRouter>)
  fireEvent.change(screen.getByLabelText('emailBase.subject'), { target: { value: 'Events' } })
  fireEvent.change(screen.getByLabelText('emailBase.body'), { target: { value: 'On Guam' } })
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.preview' }))
  await screen.findByTitle('emailBase.preview 600')
  fireEvent.click(screen.getByRole('button', { name: 'emailBase.test' }))
  await waitFor(() => expect(finishCreate).toBeTypeOf('function'))
  expect(screen.getByLabelText('emailBase.subject')).toBeDisabled()
  expect(screen.getByLabelText('emailBase.search')).toBeDisabled()
  finishCreate({ data: { id: 18 } })
  await waitFor(() => expect(screen.getByRole('button', { name: 'emailBase.test' })).not.toBeDisabled())
  expect(screen.getByRole('button', { name: 'emailBase.send' })).toBeDisabled()
})

afterEach(() => vi.useRealTimers())
it('debounces rapid filter edits and does not reload history for filters', async () => {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? { eligible: 0, count: 0, subscribers: [] } : { mailings: [] } }))
  render(<MemoryRouter initialEntries={['/dashboard/email?scope=platform']}><AudienceMailingsPage /></MemoryRouter>)
  await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
  vi.useFakeTimers()
  for (const value of ['a', 'al', 'alice']) fireEvent.change(screen.getByLabelText('emailBase.search'), { target: { value } })
  fireEvent.change(screen.getByLabelText('emailBase.source'), { target: { value: 'checkout' } })
  fireEvent.change(screen.getByLabelText('emailBase.interest'), { target: { value: 'music' } })
  fireEvent.change(screen.getByLabelText('emailBase.status'), { target: { value: 'confirmed' } })
  fireEvent.change(screen.getByLabelText('emailBase.since'), { target: { value: '2026-11-01' } })
  await vi.advanceTimersByTimeAsync(299)
  expect(apiClient.get).toHaveBeenCalledTimes(2)
  await act(async () => { await vi.advanceTimersByTimeAsync(1) })
  expect(apiClient.get).toHaveBeenCalledTimes(3)
  expect(apiClient.get).toHaveBeenLastCalledWith('/audience_mailings/audience', expect.objectContaining({ params: expect.objectContaining({ q: 'alice', source: 'checkout', interest: 'music', status: 'confirmed', since: '2026-11-01' }) }))
  expect(apiClient.get.mock.calls.filter(([path]) => path === '/audience_mailings')).toHaveLength(1)
})
it('translates history statuses, blocked reasons, and the cancellation control', async () => {
  const previous = state.t
  state.t = (key, values = {}) => {
    const text = key.split('.').reduce((value, part) => value?.[part], en)
    return typeof text === 'string' ? text.replace(/{{(\w+)}}/g, (_, name) => values[name]) : key
  }
  try {
    apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? { eligible: 0, count: 0, subscribers: [] } : { mailings: [
      { id: 1, subject: 'Upcoming', status: 'scheduled', counts: { delayed: 1 }, unsubscribed: 0 },
      { id: 2, subject: 'Held', status: 'blocked', blocked_reason: 'Invalid schedule', counts: {}, unsubscribed: 0 },
    ] } }))
    render(<MemoryRouter initialEntries={['/dashboard/email?scope=platform']}><AudienceMailingsPage /></MemoryRouter>)
    expect(await screen.findByRole('button', { name: en.emailBase.cancelScheduled })).toBeInTheDocument()
    expect(screen.getByText(/Scheduled.*Delayed: 1/)).toBeInTheDocument()
    expect(screen.getByText(/Blocked Invalid schedule/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: en.emailBase.cancelScheduled }))
    await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/1/cancel', { scope: 'platform' }, { organizationId: null }))
  } finally { state.t = previous }
})
