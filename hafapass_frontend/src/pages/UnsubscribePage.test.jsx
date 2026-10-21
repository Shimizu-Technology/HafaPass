import { beforeEach, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import apiClient from '../api/client'
import UnsubscribePage from './UnsubscribePage'

vi.mock('../api/client', () => ({ default: { get: vi.fn(), delete: vi.fn() } }))

beforeEach(() => {
  vi.clearAllMocks()
  apiClient.get.mockResolvedValue({ data: { organization: 'Island Nights', unsubscribed: true } })
})

it('confirms public unsubscribe and permits resubscribe', async () => {
  const user = userEvent.setup()
  apiClient.delete.mockResolvedValue({ data: { unsubscribed: false } })
  render(<MemoryRouter initialEntries={['/unsubscribe/signed-token']}><Routes><Route path="/unsubscribe/:token" element={<UnsubscribePage />} /></Routes></MemoryRouter>)
  expect(await screen.findByText(/You are unsubscribed from promotional emails from Island Nights/)).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Resubscribe' }))
  expect(apiClient.delete).toHaveBeenCalledWith('/marketing/unsubscribe/signed-token')
  expect(await screen.findByText(/You are resubscribed/)).toBeInTheDocument()
})
