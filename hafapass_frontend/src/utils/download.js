// Safari (notably for .pkpass and PDFs) can cancel a download whose blob URL is
// revoked in the same task as the click, so keep it alive briefly.
export function revokeObjectUrlLater(url, delay = 30_000) {
  window.setTimeout(() => window.URL.revokeObjectURL(url), delay)
}

// Saves a downloaded Blob (an API CSV export) under the given file name.
export function saveBlob(blob, filename) {
  const url = window.URL.createObjectURL(blob)
  const link = document.createElement('a')
  try {
    link.href = url
    link.download = filename
    document.body.appendChild(link)
    link.click()
  } finally {
    link.remove()
    revokeObjectUrlLater(url)
  }
}
