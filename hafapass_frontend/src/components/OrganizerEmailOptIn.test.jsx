import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { vi, it, expect } from 'vitest'
import OrganizerEmailOptIn from './OrganizerEmailOptIn'
import apiClient from '../api/client'
vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
vi.mock('react-i18next', () => ({ useTranslation: () => ({ t: key => key }) }))

it.each([404, 409])('handles a removed follow (%s) without checking the consent box', async status => {
  apiClient.get.mockResolvedValue({ data: { organizers: [{ id: 7, email_opt_in: false }] } })
  apiClient.post.mockRejectedValue({ response: { status } })
  render(<OrganizerEmailOptIn organizationId={7} />)
  const checkbox = screen.getByRole('checkbox')
  await waitFor(() => expect(checkbox).not.toBeDisabled())
  fireEvent.click(checkbox)
  expect(await screen.findByRole('alert')).toHaveTextContent('emailBase.error')
  expect(apiClient.post).toHaveBeenCalledWith('/me/organizer_follows', { organization_id: 7, email_opt_in: true, consent_only: true })
  expect(checkbox).not.toBeChecked()
  expect(checkbox).not.toBeDisabled()
})
