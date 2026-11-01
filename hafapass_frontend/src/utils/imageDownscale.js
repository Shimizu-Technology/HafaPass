// Cover photos straight from a phone are often 4000+ px and several MB, but
// pages show them at most ~1600 px wide. Shrinking in the browser keeps uploads
// fast on mobile data and removes camera metadata such as location. The server
// still validates type, size and signature exactly as before.
export const COVER_MAX_EDGE = 1600
export const COVER_QUALITY = 0.82

function makeCanvas(width, height) {
  if (typeof OffscreenCanvas === 'function') return new OffscreenCanvas(width, height)
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  return canvas
}

function encode(canvas, type, quality) {
  if (typeof canvas.convertToBlob === 'function') return canvas.convertToBlob({ type, quality })
  return new Promise(resolve => canvas.toBlob(resolve, type, quality))
}

// Returns a smaller WebP (or, where the browser cannot encode WebP, a JPEG for
// JPEG sources). Returns the original file whenever resizing is unsupported,
// fails, or would not make the file smaller.
export async function downscaleImage(file, { maxEdge = COVER_MAX_EDGE, quality = COVER_QUALITY } = {}) {
  if (typeof createImageBitmap !== 'function') return file
  let bitmap
  try {
    bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
  } catch {
    return file
  }
  try {
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height))
    const width = Math.max(1, Math.round(bitmap.width * scale))
    const height = Math.max(1, Math.round(bitmap.height * scale))
    const canvas = makeCanvas(width, height)
    const context = canvas.getContext('2d')
    if (!context) return file
    context.imageSmoothingQuality = 'high'
    context.drawImage(bitmap, 0, 0, width, height)
    let type = 'image/webp'
    let blob = await encode(canvas, type, quality)
    // Safari answers a WebP request with PNG. JPEG keeps photos small there;
    // PNG and WebP sources may be transparent, so they keep the original.
    if (blob?.type !== type) {
      if (file.type !== 'image/jpeg') return file
      type = 'image/jpeg'
      blob = await encode(canvas, type, quality)
      if (blob?.type !== type) return file
    }
    if (!blob.size || blob.size >= file.size) return file
    const name = `${file.name.replace(/\.[^.]*$/, '') || 'cover'}.${type === 'image/webp' ? 'webp' : 'jpg'}`
    return new File([blob], name, { type, lastModified: file.lastModified })
  } catch {
    return file
  } finally {
    bitmap.close?.()
  }
}
