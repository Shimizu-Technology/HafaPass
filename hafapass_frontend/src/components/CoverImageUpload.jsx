import { useState, useRef, useEffect } from 'react'
import { Upload, X, Loader2, Image as ImageIcon } from 'lucide-react'
import { uploadImage } from '../utils/uploads'

const MAX_SIZE = 5 * 1024 * 1024 // 5MB
const ACCEPTED_TYPES = ['image/jpeg', 'image/png', 'image/webp']

export default function CoverImageUpload({ currentUrl, onUploaded, disabled, eventId }) {
  const [uploading, setUploading] = useState(false)
  const [error, setError] = useState(null)
  const [preview, setPreview] = useState(null)
  const [dragOver, setDragOver] = useState(false)
  const [retryFile, setRetryFile] = useState(null)
  const inputRef = useRef(null)

  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview) }, [preview])

  const handleFile = async (file) => {
    if (!file || disabled || uploading) return
    setError(null)
    setRetryFile(null)

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
      const finalUrl = await uploadImage(file, eventId)
      onUploaded(finalUrl)
      setPreview(null)
    } catch (uploadError) {
      setError(uploadError.response?.data?.error || uploadError.message || 'Upload failed. Please try again.')
      setRetryFile(file)
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
          <div className="absolute inset-0 bg-black/0 hover:bg-black/30 transition-colors flex items-center justify-center opacity-100 sm:opacity-0 sm:hover:opacity-100 focus-within:opacity-100">
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
          role="button"
          tabIndex={disabled || uploading ? -1 : 0}
          aria-label="Upload cover image"
          onKeyDown={event => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); inputRef.current?.click() } }}
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
        onChange={(e) => { const file = e.target.files[0]; e.target.value = ''; handleFile(file) }}
      />

      {error && <p role="alert" className="mt-1 text-sm text-red-600">{error}</p>}
      {retryFile && <button type="button" className="btn-secondary mt-2" disabled={disabled || uploading} onClick={() => handleFile(retryFile)}>Retry image upload</button>}
    </div>
  )
}
