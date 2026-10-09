import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import apiClient from '../api/client'
import EnvironmentBanner from './EnvironmentBanner'

vi.mock('../api/client', () => ({ default: { get: vi.fn() } }))

describe('test environment identification', () => {
  beforeEach(() => vi.clearAllMocks())
  it('labels the actual non-production environment even when payment configuration differs', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'test', payment_mode: 'stripe' } })
    render(<EnvironmentBanner />)
    expect(await screen.findByRole('status')).toHaveTextContent('Test environment')
  })
  it('does not label a production free event as a test environment', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'production', payment_mode: 'simulate' } })
    const view = render(<EnvironmentBanner />)
    await vi.waitFor(() => expect(apiClient.get).toHaveBeenCalled())
    expect(view.container).toBeEmptyDOMElement()
  })
})
