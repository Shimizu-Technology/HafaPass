import { useEffect, useRef, useState } from 'react'
import { Download } from 'lucide-react'

export default function ActivityExportButton({ api, params, beginRequest, disabled = false }) {
  const [state, setState] = useState({ status: 'idle' })
  const active = useRef(null)
  const busy = useRef(false)

  useEffect(() => () => { active.current = null }, [])

  const run = async (id = null) => {
    if (busy.current || disabled) return
    const request = beginRequest()
    if (!request) return
    active.current = request
    busy.current = true
    const current = () => active.current === request && request.current()
    setState({ status: 'loading' })
    try {
      const response = id ? await api.exportStatus(id, request.config) : await api.createExport(params, request.config)
      if (!current()) return
      const job = response.data.export
      if (job?.status === 'failed') throw new Error('Export failed')
      if (job?.status !== 'ready' && job?.status !== 'completed') {
        if (!job?.id) throw new Error('Missing export')
        setState({ status: 'pending', id: job.id })
        return
      }
      const file = await api.downloadExport(job.id, request.config)
      if (!current()) return
      const content = typeof file.data === 'string' ? file.data : await file.data.text()
      if (!current()) return
      if (content.includes('EXPORT INCOMPLETE: an error stopped this file early.')) throw new Error('Export incomplete')
      const url = URL.createObjectURL(new Blob([file.data], { type: 'text/csv;charset=utf-8' }))
      const link = document.createElement('a')
      link.href = url
      link.download = 'activity.csv'
      document.body.appendChild(link)
      link.click()
      link.remove()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
      setState({ status: 'downloaded' })
    } catch (error) {
      if (current() && !request.handleError?.(error)) setState({ status: 'failed' })
    } finally { busy.current = false; request.release() }
  }

  return <div className="min-w-0">
    <button type="button" className="btn-secondary inline-flex min-h-11 items-center gap-2" disabled={disabled || state.status === 'loading'}
      onClick={() => run(state.status === 'pending' ? state.id : null)}>
      <Download aria-hidden="true" className="h-4 w-4 shrink-0" />
      {state.status === 'loading' ? 'Preparing CSV…' : state.status === 'pending' ? 'Check CSV status' : state.status === 'failed' ? 'Retry CSV export' : 'Download CSV'}
    </button>
    {state.status === 'failed' && <p role="alert" className="mt-2 max-w-sm text-sm text-red-700">CSV could not be downloaded. Try again.</p>}
    {state.status === 'pending' && <p role="status" className="mt-2 max-w-sm text-sm text-neutral-600">Your CSV is being prepared. Check its status in a moment.</p>}
    {state.status === 'downloaded' && <p role="status" className="mt-2 text-sm text-neutral-600">CSV downloaded.</p>}
  </div>
}
