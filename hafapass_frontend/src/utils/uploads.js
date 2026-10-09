import apiClient from '../api/client'

const inFlight = new Map()
const owner = () => window.localStorage.getItem('hafapass_scanner_user_id')

async function recoveryKey(file, eventId, userId) {
  const bytes = file.arrayBuffer ? await file.arrayBuffer() : await new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(new Error('The image could not be read. Please select it again.'))
    reader.readAsArrayBuffer(file)
  })
  const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))].map(value => value.toString(16).padStart(2, '0')).join('')
  return `hafapass:upload-completion:${userId}:${eventId || 'profile'}:${file.type}:${hash}`
}

async function completeUpload(key, uploadToken, userId) {
  if (owner() !== userId) throw new Error('Your account changed. Sign in with the original account to finish this image.')
  try {
    const completed = await apiClient.post('/uploads/complete', { upload_token: uploadToken })
    if (!completed.data.public_url) throw new Error('The uploaded image could not be verified. Retry this image upload.')
    window.sessionStorage.removeItem(key)
    return completed.data.public_url
  } catch (error) {
    // Network/5xx failures may follow a committed completion; retain its identity.
    if ([401, 403, 404, 422].includes(error.response?.status)) window.sessionStorage.removeItem(key)
    throw error
  }
}

async function upload(file, eventId, userId, key) {
  if (owner() !== userId) throw new Error('Your account changed. Please select the image again.')
  const savedToken = window.sessionStorage.getItem(key)
  if (savedToken) return completeUpload(key, savedToken, userId)
  const response = await apiClient.post('/uploads/presign', {
    filename: file.name,
    content_type: file.type,
    byte_size: file.size,
    ...(eventId ? { event_id: Number(eventId) } : {}),
  })
  const { url, fields, upload_token } = response.data
  if (!upload_token) throw new Error('Upload authorization is missing. Please try again.')
  if (owner() !== userId) throw new Error('Your account changed. Please select the image again.')
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
    window.sessionStorage.removeItem(key)
    throw new Error('Image storage could not accept this upload. Please try again.')
  }
  return completeUpload(key, upload_token, userId)
}

export async function uploadImage(file, eventId) {
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file?.type)) throw new Error('Choose a JPG, PNG, or WebP image.')
  if (!file.size || file.size > 5 * 1024 * 1024) throw new Error('Image must be between 1 byte and 5 MB.')
  const userId = owner()
  if (!userId) throw new Error('Sign in before uploading an image.')
  const key = await recoveryKey(file, eventId, userId)
  if (inFlight.has(key)) return inFlight.get(key)
  const operation = upload(file, eventId, userId, key)
  inFlight.set(key, operation)
  try { return await operation } finally { inFlight.delete(key) }
}
