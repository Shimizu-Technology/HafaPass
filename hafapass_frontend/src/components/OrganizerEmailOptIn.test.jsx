import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { vi, it, expect } from 'vitest'
import OrganizerEmailOptIn from './OrganizerEmailOptIn'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))

it('handles a removed follow (404) without checking the consent box', async () => {
  apiClient.get.mockResolvedValue({ data: { organizers: [{ id: 7, email_opt_in: false, consent_marker: 12 }] } })
  apiClient.post.mockRejectedValue({ response: { status: 404 } })
  render(<OrganizerEmailOptIn organizationId={7} />)
  const checkbox = screen.getByRole('checkbox')
  await waitFor(() => expect(checkbox).not.toBeDisabled())
  fireEvent.click(checkbox)
  expect(await screen.findByRole('alert')).toHaveTextContent('emailBase.error')
  expect(apiClient.post).toHaveBeenCalledWith('/me/organizer_follows', { organization_id: 7, email_opt_in: true, consent_only: true, consent_marker: 12 })
  expect(checkbox).not.toBeChecked()
  expect(checkbox).not.toBeDisabled()
})

it('R4: reloads withdrawn state after 409 and sends the fresh marker on a deliberate retry', async () => {
  apiClient.get.mockResolvedValueOnce({ data: { organizers: [{ id: 7, email_opt_in: false, consent_marker: 12 }] } })
    .mockResolvedValueOnce({ data: { organizers: [{ id: 7, email_opt_in: false, consent_marker: 13 }] } })
    .mockResolvedValueOnce({ data: { organizers: [{ id: 7, email_opt_in: true, consent_marker: 14 }] } })
  apiClient.post.mockRejectedValueOnce({ response: { status: 409 } }).mockResolvedValueOnce({ data: {} })
  render(<OrganizerEmailOptIn organizationId={7} />)
  const checkbox = screen.getByRole('checkbox')
  await waitFor(() => expect(checkbox).not.toBeDisabled())
  fireEvent.click(checkbox)
  expect(await screen.findByRole('alert')).toHaveTextContent('emailBase.preferencesChanged')
  expect(checkbox).not.toBeChecked()
  expect(apiClient.get).toHaveBeenCalledTimes(2)
  fireEvent.click(checkbox)
  await waitFor(() => expect(checkbox).toBeChecked())
  expect(apiClient.post).toHaveBeenLastCalledWith('/me/organizer_follows', { organization_id: 7, email_opt_in: true, consent_only: true, consent_marker: 13 })
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})
