import apiClient from '../api/client'
import { forgetUploadToken, uploadRecoveryPrefix, uploadScope, uploadScopeCurrent } from './uploadRecovery'

const inFlight = new Map()

async function recoveryKey(file, scope) {
  const bytes = file.arrayBuffer ? await file.arrayBuffer() : await new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(new Error('The image could not be read. Please select it again.'))
    reader.readAsArrayBuffer(file)
  })
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(value => value.toString(16).padStart(2, '0')).join('')
  return `${uploadRecoveryPrefix(scope)}${file.type}:${hash}`
}

function requireScope(scope) {
  if (!uploadScopeCurrent(scope)) throw new Error('Your account or organization changed. Please select the image again.')
  if (scope.isCurrent && !scope.isCurrent()) throw new Error('The image upload context changed. Please select the image again.')
}

async function completeUpload(key, uploadToken, scope) {
  requireScope(scope)
  try {
    const completed = await apiClient.post('/uploads/complete', { upload_token: uploadToken })
    requireScope(scope)
    if (!completed.data.public_url) throw new Error('The uploaded image could not be verified. Retry this image upload.')
    forgetUploadToken(key, uploadToken)
    return completed.data.public_url
  } catch (error) {
    // Network/5xx failures may follow a committed completion; retain its identity.
    if ([401, 403, 404, 422].includes(error.response?.status)) forgetUploadToken(key, uploadToken)
    throw error
  }
}

async function upload(file, eventId, scope, key) {
  requireScope(scope)
  const savedToken = window.sessionStorage.getItem(key)
  if (savedToken) {
    try {
      return await completeUpload(key, savedToken, scope)
    } catch (error) {
      // Missing bytes/expired authorization can restart this image operation.
      // Authentication and permission failures cannot authorize a fresh upload.
      if (![404, 422].includes(error.response?.status)) throw error
      requireScope(scope)
      // Another operation may have replaced this token while completion ran.
      if (window.sessionStorage.getItem(key)) throw error
    }
  }
  const response = await apiClient.post('/uploads/presign', {
    filename: file.name,
    content_type: file.type,
    byte_size: file.size,
    ...(eventId ? { event_id: Number(eventId) } : {}),
  })
  const { url, fields, upload_token } = response.data
  if (!upload_token) throw new Error('Upload authorization is missing. Please try again.')
  requireScope(scope)
  // Persist before storage receives bytes. An interrupted upload/completion can
  // be verified through the same server receipt after retry or page reload.
  window.sessionStorage.setItem(key, upload_token)
  let uploaded
  if (fields) {
    const body = new FormData()
    Object.entries(fields).forEach(([key, value]) => body.append(key, value))
    body.append('file', file)
    uploaded = await fetch(url, { method: 'POST', body })
  } else {
    uploaded = await fetch(url, { method: 'PUT', headers: { 'Content-Type': file.type }, body: file })
  }
  if (!uploaded.ok) {
    forgetUploadToken(key, upload_token)
    throw new Error('Image storage could not accept this upload. Please try again.')
  }
  return completeUpload(key, upload_token, scope)
}

export async function uploadImage(file, eventId, isCurrent) {
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file?.type)) throw new Error('Choose a JPG, PNG, or WebP image.')
  if (!file.size || file.size > 5 * 1024 * 1024) throw new Error('Image must be between 1 byte and 5 MB.')
  const scope = { ...uploadScope(eventId), isCurrent }
  if (!scope.userId) throw new Error('Sign in before uploading an image.')
  const key = await recoveryKey(file, scope)
  if (inFlight.has(key)) return inFlight.get(key)
  const operation = upload(file, eventId, scope, key)
  inFlight.set(key, operation)
  try { return await operation } finally { inFlight.delete(key) }
}
