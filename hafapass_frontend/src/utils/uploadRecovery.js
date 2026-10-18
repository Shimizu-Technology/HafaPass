const prefix = 'hafapass:upload-completion:'

export function uploadScope(eventId) {
  return {
    userId: window.localStorage.getItem('hafapass_scanner_user_id'),
    organizationId: window.localStorage.getItem('hafapass_organization_id') || 'default',
    eventId: eventId ? String(eventId) : 'profile',
  }
}

export function uploadScopeCurrent(scope) {
  const current = uploadScope(scope.eventId === 'profile' ? null : scope.eventId)
  return current.userId === scope.userId && current.organizationId === scope.organizationId
}

export function uploadRecoveryPrefix(scope) {
  return `${prefix}${encodeURIComponent(scope.userId)}:${encodeURIComponent(scope.organizationId)}:${scope.eventId}:`
}

export function forgetUploadToken(key, token) {
  if (window.sessionStorage.getItem(key) === token) window.sessionStorage.removeItem(key)
}

export function clearUploadRecovery(userId) {
  const ownerPrefix = `${prefix}${encodeURIComponent(userId)}:`
  for (let index = window.sessionStorage.length - 1; index >= 0; index -= 1) {
    const key = window.sessionStorage.key(index)
    if (key?.startsWith(ownerPrefix)) window.sessionStorage.removeItem(key)
  }
}
