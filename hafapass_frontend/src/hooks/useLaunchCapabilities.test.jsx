import { act, renderHook, waitFor } from '@testing-library/react'
import { beforeEach, expect, it, vi } from 'vitest'
import { loadPublicConfig } from '../api/publicConfig'
import useLaunchCapabilities, { useLaunchCapabilityState } from './useLaunchCapabilities'

vi.mock('../api/publicConfig', () => ({ loadPublicConfig: vi.fn() }))

beforeEach(() => loadPublicConfig.mockReset())

it('reports loading, then the platform capabilities', async () => {
  loadPublicConfig.mockResolvedValue({ data: { launch_capabilities: { door_card: true } } })
  const { result } = renderHook(() => useLaunchCapabilityState())
  expect(result.current.status).toBe('loading')
  await waitFor(() => expect(result.current.status).toBe('ready'))
  expect(result.current.capabilities).toEqual({ door_card: true })
})

it('reports a failed check as an error, never as disabled, and retries', async () => {
  loadPublicConfig.mockRejectedValueOnce(new Error('timeout'))
    .mockResolvedValueOnce({ data: { launch_capabilities: { door_card: true } } })
  const { result } = renderHook(() => useLaunchCapabilityState())
  await waitFor(() => expect(result.current.status).toBe('error'))
  act(() => result.current.retry())
  await waitFor(() => expect(result.current.status).toBe('ready'))
  expect(result.current.capabilities.door_card).toBe(true)
})

it('keeps the plain capabilities object for existing callers', async () => {
  loadPublicConfig.mockResolvedValue({ data: { launch_capabilities: { ticket_transfers: true } } })
  const { result } = renderHook(() => useLaunchCapabilities())
  await waitFor(() => expect(result.current).toEqual({ ticket_transfers: true }))
})
