import apiClient from './client'

// Keep the caller's account/organization fence on reads, exports and downloads.
export const organizerActivityApi = {
  list: (params, config) => apiClient.get('/organizer/activity_logs', { ...config, params }),
  createExport: (params, config) => apiClient.post('/organizer/activity_log_exports', params, config),
  exportStatus: (id, config) => apiClient.get(`/organizer/activity_log_exports/${encodeURIComponent(id)}`, config),
  downloadExport: (id, config) => apiClient.get(`/organizer/activity_log_exports/${encodeURIComponent(id)}/download`, { ...config, responseType: 'blob' }),
}

export const adminActivityApi = {
  list: (params, config) => apiClient.get('/admin/audit_logs', { ...config, params }),
  createExport: (params, config) => apiClient.post('/admin/activity_log_exports', params, config),
  exportStatus: (id, config) => apiClient.get(`/admin/activity_log_exports/${encodeURIComponent(id)}`, config),
  downloadExport: (id, config) => apiClient.get(`/admin/activity_log_exports/${encodeURIComponent(id)}/download`, { ...config, responseType: 'blob' }),
}
