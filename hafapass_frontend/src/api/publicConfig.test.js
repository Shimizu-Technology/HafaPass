import { describe, expect, it, vi } from 'vitest'
import apiClient from './client'
import { loadPublicConfig } from './publicConfig'

vi.mock('./client', () => ({ default: { get: vi.fn() } }))

describe('public boot configuration', () => {
  it('shares concurrent callers and refreshes after success', async () => {
    apiClient.get.mockResolvedValue({ data: { environment: 'production' } })
    const first = loadPublicConfig()
    expect(loadPublicConfig()).toBe(first)
    await first
    expect(apiClient.get).toHaveBeenCalledTimes(1)
    await loadPublicConfig()
    expect(apiClient.get).toHaveBeenCalledTimes(2)
  })

  it('allows a fresh retry after failure', async () => {
    apiClient.get.mockReset().mockRejectedValueOnce(new Error('offline')).mockResolvedValue({ data: {} })
    await expect(loadPublicConfig()).rejects.toThrow('offline')
    await expect(loadPublicConfig()).resolves.toEqual({ data: {} })
    expect(apiClient.get).toHaveBeenCalledTimes(2)
  })
})
