import { act, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { vi, it, expect, afterEach, beforeEach } from 'vitest'
import AudienceMailingsPage from './AudienceMailingsPage'
import apiClient from '../api/client'

const state = vi.hoisted(() => ({ identity: { ready: true, accountKey: 'admin', organizationId: null, authContext: null } }))
vi.mock('../hooks/useOrganizerContext', () => ({ useOrganizerIdentity: () => state.identity }))
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

const PLATFORM = '/dashboard/email?scope=platform'
const audienceData = (overrides = {}) => ({ eligible: 1, count: 1, considered: 1, subscribers: [{ id: 1, email: 'alerts@example.test', status: 'confirmed' }], ...overrides })
const renderPage = (url = PLATFORM) => render(<MemoryRouter initialEntries={[url]}><AudienceMailingsPage /></MemoryRouter>)

beforeEach(() => { vi.clearAllMocks() })
afterEach(() => vi.useRealTimers())

async function writeAndPreview() {
  fireEvent.click(await screen.findByRole('button', { name: 'Next: write the email' }))
  fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'Events' } })
  fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'On Guam' } })
  fireEvent.click(screen.getByRole('button', { name: 'Next: preview' }))
}

it('walks audience → write → preview → test → confirm → send, sending only the tested draft', async () => {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData() : { mailings: [] } }))
  apiClient.post.mockImplementation(path => Promise.resolve({ data: path.endsWith('/preview') ? { html: '<p>Exact rendered email</p>', eligible: 1 }
    : path.endsWith('/test_send') ? { queued: true, recipient: 'me@example.test' } : { id: 17 } }))
  renderPage()
  expect(await screen.findByRole('status')).toHaveTextContent('1 person will get this email')
  await writeAndPreview()
  const frame = await screen.findByTitle('Email preview, Desktop')
  expect(frame).toHaveAttribute('srcdoc', '<p>Exact rendered email</p>')
  expect(frame).toHaveAttribute('sandbox', '')
  expect(screen.getByTestId('email-preview-frame')).toHaveAttribute('data-width', '600')
  fireEvent.click(screen.getByRole('button', { name: 'Phone' }))
  expect(screen.getByTitle('Email preview, Phone')).toHaveStyle({ width: '375px' })
  expect(screen.getByTestId('email-preview-frame')).toHaveAttribute('data-width', '375')
  expect(screen.getByText('Full size: 375 px wide')).toBeInTheDocument()

  fireEvent.click(screen.getByRole('button', { name: 'Next: choose when to send' }))
  expect(screen.getByRole('button', { name: 'Review and send' })).toBeDisabled()
  expect(screen.getByText('Send a test to yourself first (step 3).')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Back' }))

  fireEvent.click(await screen.findByRole('button', { name: 'Send test to me' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/test_send', { scope: 'platform' }, { organizationId: null }))
  expect(await screen.findByText(/Test queued for me@example.test/)).toBeInTheDocument()
  expect(screen.getByText('Queued for you')).toBeInTheDocument()

  fireEvent.click(screen.getByRole('button', { name: 'Next: choose when to send' }))
  fireEvent.click(screen.getByRole('button', { name: 'Review and send' }))
  const dialog = screen.getByRole('dialog')
  expect(within(dialog).getByRole('heading')).toHaveTextContent('Send to about 1 person now?')
  expect(within(dialog).getByText('Events')).toBeInTheDocument()
  expect(within(dialog).getByText('About 1 person (final count when it sends)')).toBeInTheDocument()
  expect(document.activeElement).toHaveTextContent('Go back')
  fireEvent.click(within(dialog).getByRole('button', { name: 'Send now' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/send_now', { scope: 'platform', scheduled_at: null }, { organizationId: null }))
  expect(await screen.findByText('Your email is on its way')).toBeInTheDocument()
  expect(screen.getByText('We’re sending it to about 1 person. The final count is set when it sends. Track delivery in History.')).toBeInTheDocument()
})

it('ignores superseded search results', async () => {
  let finishOld
  apiClient.get.mockImplementation((path, config) => {
    if (!path.endsWith('/audience')) return Promise.resolve({ data: { mailings: [] } })
    if (config.params.q === 'alice') return new Promise(resolve => { finishOld = resolve })
    return Promise.resolve({ data: audienceData({ eligible: config.params.q ? 2 : 1 }) })
  })
  renderPage()
  await screen.findByText('1 person will get this email')
  fireEvent.change(screen.getByLabelText('Search by email'), { target: { value: 'alice' } })
  await waitFor(() => expect(finishOld).toBeTypeOf('function'))
  fireEvent.change(screen.getByLabelText('Search by email'), { target: { value: 'bob' } })
  await screen.findByText('2 people will get this email')
  await act(async () => { finishOld({ data: audienceData({ eligible: 9 }) }) })
  expect(screen.getByRole('status')).toHaveTextContent('2 people will get this email')
})

it('locks the flow while creating a draft and requires a successful test before sending', async () => {
  let finishCreate
  apiClient.get.mockResolvedValue({ data: { ...audienceData(), mailings: [] } })
  apiClient.post.mockImplementation(path => path.endsWith('/preview') ? Promise.resolve({ data: { html: '<p>Preview</p>', eligible: 1 } })
    : path === '/audience_mailings' ? new Promise(resolve => { finishCreate = resolve }) : Promise.reject(new Error('test failed')))
  renderPage()
  await writeAndPreview()
  await screen.findByTitle('Email preview, Desktop')
  fireEvent.click(screen.getByRole('button', { name: 'Send test to me' }))
  await waitFor(() => expect(finishCreate).toBeTypeOf('function'))
  expect(screen.getByRole('button', { name: 'Sending test…' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Back' })).toBeDisabled()
  expect(screen.getByRole('button', { name: 'Next: choose when to send' })).toBeDisabled()
  await act(async () => { finishCreate({ data: { id: 18 } }) })
  expect(await screen.findByText('We couldn’t send the test. Check your access and try again.')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Next: choose when to send' }))
  expect(screen.getByRole('button', { name: 'Review and send' })).toBeDisabled()
})

it('debounces rapid filter edits and does not reload history for filters', async () => {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData({ eligible: 0, count: 0, considered: 0, subscribers: [] }) : { mailings: [] } }))
  renderPage()
  await waitFor(() => expect(apiClient.get).toHaveBeenCalledTimes(2))
  vi.useFakeTimers()
  for (const value of ['a', 'al', 'alice']) fireEvent.change(screen.getByLabelText('Search by email'), { target: { value } })
  fireEvent.change(screen.getByLabelText('Signed up from'), { target: { value: 'checkout' } })
  fireEvent.change(screen.getByLabelText('Interest'), { target: { value: 'music' } })
  fireEvent.change(screen.getByLabelText('Signup status'), { target: { value: 'confirmed' } })
  fireEvent.change(screen.getByLabelText('Signed up on or after'), { target: { value: '2026-11-01' } })
  await vi.advanceTimersByTimeAsync(299)
  expect(apiClient.get).toHaveBeenCalledTimes(2)
  await act(async () => { await vi.advanceTimersByTimeAsync(1) })
  expect(apiClient.get).toHaveBeenCalledTimes(3)
  expect(apiClient.get).toHaveBeenLastCalledWith('/audience_mailings/audience', expect.objectContaining({ params: expect.objectContaining({ q: 'alice', source: 'checkout', interest: 'music', status: 'confirmed', since: '2026-11-01' }) }))
  expect(apiClient.get.mock.calls.filter(([path]) => path === '/audience_mailings')).toHaveLength(1)
  expect(screen.getByRole('button', { name: /Narrow the list/ })).toHaveTextContent('5 filters on')
})

it('explains who is left out and why, with one status region for the count', async () => {
  apiClient.get.mockImplementation((path, config) => Promise.resolve({ data: path.endsWith('/audience')
    ? audienceData({ eligible: config.params.q ? 48000 : 312, considered: config.params.q ? 48000 : 336, count: 336, status_breakdown: { confirmed: 314, pending: 9, unsubscribed: 7, bounced: 4, complained: 2 } })
    : { mailings: [] } }))
  renderPage()
  await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('312 people will get this email'))
  expect(screen.getByText('24 people left out')).toBeInTheDocument()
  expect(screen.getByText('9 haven’t confirmed their signup yet')).toBeInTheDocument()
  expect(screen.getByText('7 unsubscribed')).toBeInTheDocument()
  expect(screen.getByText('6 bounced or marked an email as spam')).toBeInTheDocument()
  expect(screen.getByText('2 opted out of all marketing or can’t receive email')).toBeInTheDocument()
  const countStatus = screen.getByRole('status')
  fireEvent.change(screen.getByLabelText('Search by email'), { target: { value: 'new' } })
  await waitFor(() => expect(countStatus).toHaveTextContent('48,000 people will get this email'))
  expect(screen.getAllByRole('status')).toHaveLength(1)
  expect(document.querySelectorAll('[aria-live]')).toHaveLength(0)
})

it('says what to do when no one can get the email', async () => {
  const lists = { buyers: { eligible: 0, count: 0, considered: 0 }, waitlists: { eligible: 0, count: 0, considered: 37 } }
  apiClient.get.mockImplementation((path, config) => Promise.resolve({ data: path.endsWith('/audience') ? { subscribers: [], ...lists[config.params.audience] } : { mailings: [] } }))
  state.identity = { ...state.identity, organizationId: '7' }
  try {
    renderPage('/dashboard/email')
    expect(await screen.findByText('No one is on this list yet')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('radio', { name: /Waitlist members/ }))
    expect(await screen.findByText('No waitlist members can get this email')).toBeInTheDocument()
    expect(screen.getByText('37 people left out')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Next: write the email' }))
    fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'Hi' } })
    fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'Body' } })
    apiClient.post.mockResolvedValue({ data: { html: '<p>x</p>', eligible: 0 } })
    fireEvent.click(screen.getByRole('button', { name: 'Next: preview' }))
    await screen.findByTitle('Email preview, Desktop')
    fireEvent.click(screen.getByRole('button', { name: 'Next: choose when to send' }))
    expect(screen.getByText('No one on this list can get email yet (step 1).')).toBeInTheDocument()
  } finally { state.identity = { ...state.identity, organizationId: null } }
})

it('blocks writing forward until subject and message exist, and explains a missing mailing address', async () => {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData() : { mailings: [] } }))
  apiClient.post.mockRejectedValue({ response: { status: 422, data: { error: 'Certified postal address required' } } })
  renderPage()
  fireEvent.click(await screen.findByRole('button', { name: 'Next: write the email' }))
  fireEvent.click(screen.getByRole('button', { name: 'Next: preview' }))
  expect(screen.getByText('Add a subject.')).toBeInTheDocument()
  expect(screen.getByLabelText('Subject')).toHaveAttribute('aria-invalid', 'true')
  fireEvent.change(screen.getByLabelText('Subject'), { target: { value: 'Events' } })
  fireEvent.change(screen.getByLabelText('Message'), { target: { value: 'Body' } })
  fireEvent.click(screen.getByRole('button', { name: 'Next: preview' }))
  expect(await screen.findByRole('alert')).toHaveTextContent('HåfaPass’s mailing address isn’t set up')
  expect(screen.getByRole('button', { name: 'Send test to me' })).toBeDisabled()
})

it('shows history states and reasons, and cancels a scheduled send only after confirmation', async () => {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData() : { mailings: [
    { id: 1, subject: 'Upcoming', status: 'scheduled', scheduled_at: '2999-01-01T00:00:00Z', created_at: '2026-11-20T00:00:00Z', counts: {}, unsubscribed: 0, audience: 'platform' },
    { id: 2, subject: 'Held', status: 'blocked', blocked_reason: 'Invalid schedule', created_at: '2026-11-19T00:00:00Z', counts: {}, unsubscribed: 0, audience: 'platform' },
    { id: 3, subject: 'Done', status: 'queued', recipient_count: 1, created_at: '2026-11-18T00:00:00Z', scheduled_at: '2026-11-18T00:00:00Z', counts: { delivered: 1 }, unsubscribed: 1, audience: 'platform' },
  ] } }))
  apiClient.post.mockResolvedValue({ data: {} })
  renderPage(`${PLATFORM}&view=history`)
  expect(await screen.findByText('Scheduled')).toBeInTheDocument()
  expect(screen.getByText('Not sent')).toBeInTheDocument()
  expect(screen.getByText('It wasn’t sent because its scheduled time was invalid.')).toBeInTheDocument()
  expect(screen.getByText('1 recipient · 1 delivered · 1 unsubscribed')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Open details for Upcoming' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel scheduled send' }))
  expect(apiClient.post).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole('button', { name: 'Yes, cancel it' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/1/cancel', { scope: 'platform' }, { organizationId: null }))
  expect(await screen.findByText('The scheduled email was cancelled.')).toBeInTheDocument()
})

it('pages long history and continues a draft at the preview step without counting an old test', async () => {
  const mailings = Array.from({ length: 45 }, (_, index) => ({ id: index + 1, subject: `Roundup ${index + 1}`, status: 'queued', recipient_count: 10, created_at: '2026-11-01T00:00:00Z', counts: { delivered: 10 }, unsubscribed: 0, audience: 'platform' }))
  mailings.unshift({ id: 99, subject: 'Saved draft', body: 'Draft body', status: 'draft', filters: { source: 'checkout' }, created_at: '2026-11-24T00:00:00Z', counts: {}, unsubscribed: 0, audience: 'platform' })
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData() : { mailings } }))
  apiClient.post.mockResolvedValue({ data: { html: '<p>draft</p>', eligible: 1 } })
  renderPage(`${PLATFORM}&view=history`)
  expect(await screen.findByText('Showing 20 of 46')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Show 20 more' }))
  fireEvent.click(screen.getByRole('button', { name: 'Show 6 more' }))
  expect(screen.queryByRole('button', { name: /more/ })).not.toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Open details for Saved draft' }))
  fireEvent.click(screen.getByRole('button', { name: 'Continue this draft' }))
  expect(await screen.findByTitle('Email preview, Desktop')).toBeInTheDocument()
  expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/preview', expect.objectContaining({ subject: 'Saved draft', body: 'Draft body', source: 'checkout' }), { organizationId: null })
  expect(screen.getByText('Not sent yet')).toBeInTheDocument()
  expect(screen.getByText('Filtered: Signed up from: Checkout')).toBeInTheDocument()
})

it('confirms before unsubscribing a platform subscriber and shows consent history in words', async () => {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData({ subscribers: [{ id: 5, email: 'alerts@example.test', status: 'confirmed', source: 'checkout', consents: [{ action: 'confirmed', version: 'event-alerts-v1', created_at: '2026-11-01T00:00:00Z' }] }] }) : { mailings: [] } }))
  apiClient.post.mockResolvedValue({ data: null })
  renderPage()
  fireEvent.click(await screen.findByRole('button', { name: 'See who’s on the list' }))
  expect(screen.getByText('Confirmed by email link')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Unsubscribe this person' }))
  expect(screen.getByRole('dialog')).toHaveTextContent('Unsubscribe alerts@example.test?')
  expect(apiClient.post).not.toHaveBeenCalled()
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Unsubscribe' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/suppress/5', {}, { organizationId: null, params: { scope: 'platform' } }))
  expect(await screen.findByText('alerts@example.test is unsubscribed.')).toBeInTheDocument()
})

// Review round 1 regressions (PR #244).
const pad = value => String(value).padStart(2, '0')
const localInput = ms => { const d = new Date(ms); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}` }

async function reachSendStep(sendNowReply) {
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData() : { mailings: [] } }))
  apiClient.post.mockImplementation((path, body) => Promise.resolve({ data: path.endsWith('/preview') ? { html: '<p>x</p>', eligible: 1 }
    : path.endsWith('/test_send') ? { queued: true, recipient: 'me@example.test' } : path.endsWith('/send_now') ? sendNowReply(body) : { id: 17 } }))
  renderPage()
  await screen.findByText('1 person will get this email')
  await writeAndPreview()
  fireEvent.click(await screen.findByRole('button', { name: 'Send test to me' }))
  await screen.findByText(/Test queued for/)
  fireEvent.click(screen.getByRole('button', { name: 'Next: choose when to send' }))
  fireEvent.click(screen.getByRole('radio', { name: /Schedule for later/ }))
}

it('#3: asks before sending when the scheduled time passes while the confirm dialog is open', async () => {
  const realNow = Date.now()
  await reachSendStep(body => ({ id: 17, status: 'scheduled', scheduled_at: body.scheduled_at || new Date().toISOString() }))
  fireEvent.change(screen.getByLabelText(/Date and time/), { target: { value: localInput(realNow + 10 * 60_000) } })
  fireEvent.click(screen.getByRole('button', { name: 'Review and send' }))
  expect(within(screen.getByRole('dialog')).getByRole('heading')).toHaveTextContent('Schedule for about 1 person?')

  const clock = vi.spyOn(Date, 'now').mockReturnValue(realNow + 20 * 60_000)
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Schedule' }))
  expect(await screen.findByText('That time has already passed')).toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalledWith('/audience_mailings/17/send_now', expect.anything(), expect.anything())

  fireEvent.click(screen.getByRole('button', { name: 'Send now instead' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/send_now', { scope: 'platform', scheduled_at: null }, { organizationId: null }))
  expect(await screen.findByText('Your email is on its way')).toBeInTheDocument()
  clock.mockRestore()
})

it('#3: reports a schedule from the server reply, not from what was picked', async () => {
  const realNow = Date.now()
  const at = localInput(realNow + 2 * 3_600_000)
  await reachSendStep(body => ({ id: 17, status: 'scheduled', scheduled_at: body.scheduled_at }))
  fireEvent.change(screen.getByLabelText(/Date and time/), { target: { value: at } })
  fireEvent.click(screen.getByRole('button', { name: 'Review and send' }))
  fireEvent.click(within(screen.getByRole('dialog')).getByRole('button', { name: 'Schedule' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/send_now', { scope: 'platform', scheduled_at: new Date(at).toISOString() }, { organizationId: null }))
  expect(await screen.findByText('Your email is scheduled')).toBeInTheDocument()
})

it('#4 #5: shows delivery outcomes and keeps Cancel while the server still says scheduled', async () => {
  const past = new Date(Date.now() - 120_000).toISOString()
  apiClient.get.mockImplementation(path => Promise.resolve({ data: path.endsWith('/audience') ? audienceData() : { mailings: [
    { id: 1, subject: 'Starting soon', status: 'scheduled', scheduled_at: past, created_at: '2026-11-20T00:00:00Z', counts: {}, unsubscribed: 0, audience: 'platform', recipient_count: 0 },
    { id: 2, subject: 'All suppressed', status: 'queued', recipient_count: 50, scheduled_at: '2026-11-19T00:00:00Z', created_at: '2026-11-19T00:00:00Z', counts: { suppressed: 48, failed: 2 }, unsubscribed: 0, audience: 'platform' },
    { id: 3, subject: 'Mostly sent', status: 'queued', recipient_count: 290, scheduled_at: '2026-11-18T00:00:00Z', created_at: '2026-11-18T00:00:00Z', counts: { delivered: 280, suppressed: 10 }, unsubscribed: 0, audience: 'platform' },
  ] } }))
  apiClient.post.mockRejectedValue({ response: { status: 409, data: {} } })
  renderPage(`${PLATFORM}&view=history`)
  expect(await screen.findByText('Not delivered')).toBeInTheDocument()
  expect(screen.getByText('Not delivered: 48 skipped (unsubscribed or blocked by send time), 2 failed.')).toBeInTheDocument()
  expect(screen.getByText('Partly sent')).toBeInTheDocument()
  expect(screen.getByText('290 recipients · 280 delivered · 10 not sent')).toBeInTheDocument()
  expect(screen.queryByText('Sent')).not.toBeInTheDocument()

  expect(screen.getByText('Starting')).toBeInTheDocument()
  fireEvent.click(screen.getByRole('button', { name: 'Open details for Starting soon' }))
  fireEvent.click(screen.getByRole('button', { name: 'Cancel scheduled send' }))
  fireEvent.click(screen.getByRole('button', { name: 'Yes, cancel it' }))
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/1/cancel', { scope: 'platform' }, { organizationId: null }))
  expect(await screen.findByText('It had already started sending, so it couldn’t be cancelled. History shows where it stands now.')).toBeInTheDocument()
})
