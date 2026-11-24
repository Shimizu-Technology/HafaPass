import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { vi, it, expect } from 'vitest'
import AudienceMailingsPage from './AudienceMailingsPage'
import apiClient from '../api/client'
const state = vi.hoisted(() => ({ identity: { ready: true, accountKey: 'admin', organizationId: null, authContext: null }, t: key => key }))
vi.mock('../hooks/useOrganizerContext', () => ({ useOrganizerIdentity: () => state.identity }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: state.t }) }))
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
it('previews desktop/mobile HTML, self-tests, then sends only the saved draft', async () => {
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
  await waitFor(() => expect(apiClient.post).toHaveBeenCalledWith('/audience_mailings/17/send_now', { scope: 'platform', scheduled_at: null }, { organizationId: null }))
})
