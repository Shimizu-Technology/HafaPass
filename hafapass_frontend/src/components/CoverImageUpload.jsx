import { useState, useRef } from 'react'
import { Upload, X, Loader2, Image as ImageIcon } from 'lucide-react'
import apiClient from '../api/client'

const MAX_SIZE = 5 * 1024 * 1024 // 5MB
const ACCEPTED_TYPES = ['image/jpeg', 'image/png', 'image/webp']

export default function CoverImageUpload({ currentUrl, onUploaded, disabled }) {
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState(null)
  const [preview, setPreview] = useState(null)
  const [dragOver, setDragOver] = useState(false)
  const inputRef = useRef(null)

  const handleFile = async (file) => {
    if (!file) return
    setError(null)

    if (!ACCEPTED_TYPES.includes(file.type)) {
      setError('Please upload a JPG, PNG, or WebP image.')
      return
    }
    if (file.size > MAX_SIZE) {
      setError('Image must be under 5MB.')
      return
    }

    // Show local preview immediately
    const localUrl = URL.createObjectURL(file)
    setPreview(localUrl)
    setUploading(true)

    try {
      // 1. Get presigned URL
      const presignRes = await apiClient.post('/uploads/presign', {
        filename: file.name,
        content_type: file.type
      })
      const { url, fields, public_url } = presignRes.data

      // 2. Upload to S3
      if (fields) {
        // Presigned POST
        const formData = new FormData()
        Object.entries(fields).forEach(([k, v]) => formData.append(k, v))
        formData.append('file', file)
        await fetch(url, { method: 'POST', body: formData })
      } else {
        // Presigned PUT
        await fetch(url, {
          method: 'PUT',
          headers: { 'Content-Type': file.type },
          body: file
        })
      }

      // 3. Notify parent with the S3 URL
      const finalUrl = public_url || url.split('?')[0]
      onUploaded(finalUrl)
    } catch {
      setError('Upload failed. Please try again.')
      setPreview(null)
    } finally {
      setUploading(false)
    }
  }

  const handleDrop = (e) => {
    e.preventDefault()
    setDragOver(false)
    handleFile(e.dataTransfer.files[0])
  }

  const displayUrl = preview || currentUrl

  return (
    <div>
      <label className="block text-sm font-medium text-neutral-700 mb-1">Cover Image</label>

      {displayUrl ? (
        <div className="relative rounded-xl overflow-hidden border border-neutral-200">
          <img src={displayUrl} alt="Cover" className="w-full h-48 object-cover" />
          <div className="absolute inset-0 bg-black/0 hover:bg-black/30 transition-colors flex items-center justify-center opacity-0 hover:opacity-100">
            <button
              type="button"
              onClick={() => inputRef.current?.click()}
              disabled={disabled || uploading}
              className="bg-white/90 text-neutral-700 px-3 py-1.5 rounded-lg text-sm font-medium"
            >
              {uploading ? 'Uploading...' : 'Replace Image'}
            </button>
          </div>
          {uploading && (
            <div className="absolute inset-0 bg-black/40 flex items-center justify-center">
              <Loader2 className="w-8 h-8 text-white animate-spin" />
            </div>
          )}
        </div>
      ) : (
        <div
          onDragOver={(e) => { e.preventDefault(); setDragOver(true) }}
          onDragLeave={() => setDragOver(false)}
          onDrop={handleDrop}
          onClick={() => inputRef.current?.click()}
          className={`border-2 border-dashed rounded-xl p-8 text-center cursor-pointer transition-colors ${
            dragOver ? 'border-brand-400 bg-brand-50' : 'border-neutral-300 hover:border-brand-300 hover:bg-neutral-50'
          } ${disabled || uploading ? 'opacity-50 pointer-events-none' : ''}`}
        >
          {uploading ? (
            <Loader2 className="w-8 h-8 text-brand-500 animate-spin mx-auto mb-2" />
          ) : (
            <Upload className="w-8 h-8 text-neutral-400 mx-auto mb-2" />
          )}
          <p className="text-sm text-neutral-600 font-medium">
            {uploading ? 'Uploading...' : 'Drop an image here, or click to browse'}
          </p>
          <p className="text-xs text-neutral-400 mt-1">JPG, PNG, or WebP · Max 5MB</p>
        </div>
      )}

      <input
        ref={inputRef}
        type="file"
        accept=".jpg,.jpeg,.png,.webp"
        className="hidden"
        onChange={(e) => handleFile(e.target.files[0])}
      />

      {error && <p className="mt-1 text-sm text-red-600">{error}</p>}
    </div>
  )
}
