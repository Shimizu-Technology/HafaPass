import apiClient from '../api/client'

export async function uploadImage(file, eventId) {
  const response = await apiClient.post('/uploads/presign', {
    filename: file.name,
    content_type: file.type,
    byte_size: file.size,
    ...(eventId ? { event_id: Number(eventId) } : {}),
  })
  const { url, fields, upload_token } = response.data
  if (!upload_token) throw new Error('Upload authorization is missing. Please try again.')
  let uploaded
  if (fields) {
    const body = new FormData()
    Object.entries(fields).forEach(([key, value]) => body.append(key, value))
    body.append('file', file)
    uploaded = await fetch(url, { method: 'POST', body })
  } else {
    uploaded = await fetch(url, { method: 'PUT', headers: { 'Content-Type': file.type }, body: file })
  }
  if (!uploaded.ok) throw new Error('Image storage could not accept this upload. Please try again.')
  const completed = await apiClient.post('/uploads/complete', { upload_token })
  if (!completed.data.public_url) throw new Error('The uploaded image could not be verified. Please try again.')
  return completed.data.public_url
}
