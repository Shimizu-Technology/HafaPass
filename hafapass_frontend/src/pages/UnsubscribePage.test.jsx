import { beforeEach, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../api/client'
import UnsubscribePage from './UnsubscribePage'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { organization: 'Island Nights', unsubscribed: false } })
})

it('uses GET for confirmation and POST for unsubscribe, without an old-link resubscribe action', async () => {
  const user = userEvent.setup()
  apiClient.post.mockResolvedValue({ data: { unsubscribed: true } })
  render(<MemoryRouter initialEntries={['/unsubscribe/signed-token']}><Routes><Route path="/unsubscribe/:token" element={<UnsubscribePage />} /></Routes></MemoryRouter>)
  expect(await screen.findByText(/Unsubscribe from promotional emails from Island Nights/)).toBeInTheDocument()
  expect(apiClient.post).not.toHaveBeenCalled()
  await user.click(screen.getByRole('button', { name: 'Unsubscribe' }))
  expect(apiClient.post).toHaveBeenCalledWith('/marketing/unsubscribe/signed-token', {})
  expect(await screen.findByText(/To get updates again, opt in at your next checkout/)).toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Resubscribe' })).not.toBeInTheDocument()
})
