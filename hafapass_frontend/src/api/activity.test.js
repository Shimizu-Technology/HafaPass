import { beforeEach, expect, it, vi } from 'vitest'
import apiClient from './client'
import { adminActivityApi, organizerActivityApi } from './activity'

vi.mock('./client', () => ({ default: { get: vi.fn(), post: vi.fn() } }))
beforeEach(() => vi.clearAllMocks())

it.each([
  [organizerActivityApi, '/organizer/activity_logs', '/organizer/activity_log_exports'],
  [adminActivityApi, '/admin/audit_logs', '/admin/activity_log_exports'],
])('keeps filters and authorization configuration on every activity operation', (api, listPath, exportPath) => {
  const config = { organizationId: '7', signal: new AbortController().signal, authContext: { generation: 8 } }
  const params = { actor_user_id: '4', event_id: '2', q: 'refund', from: '2026-10-22' }
  api.list(params, config)
  expect(apiClient.get).toHaveBeenLastCalledWith(listPath, { ...config, params })
  api.createExport(params, config)
  expect(apiClient.post).toHaveBeenLastCalledWith(exportPath, params, config)
  api.exportStatus(19, config)
  expect(apiClient.get).toHaveBeenLastCalledWith(`${exportPath}/19`, config)
  api.downloadExport(19, config)
  expect(apiClient.get).toHaveBeenLastCalledWith(`${exportPath}/19/download`, { ...config, responseType: 'blob' })
  api.downloadExport('opaque/signed+token', config)
  expect(apiClient.get).toHaveBeenLastCalledWith(`${exportPath}/opaque%2Fsigned%2Btoken/download`, { ...config, responseType: 'blob' })
})
