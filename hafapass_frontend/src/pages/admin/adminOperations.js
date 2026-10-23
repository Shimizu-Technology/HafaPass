import { formatPlatformDateTime } from '../../utils/eventTime'
import { useCallback, useEffect, useRef, useState } from 'react'
import apiClient from '../../api/client'
import { usePlatformRequests } from '../../hooks/usePlatformContext'
import { formatMoneyCents } from '../../utils/money'

export const money = (cents, currency = 'usd') => formatMoneyCents(cents, String(currency || 'usd').toUpperCase())

export const formatDateTime = formatPlatformDateTime

export function formatDate(value) {
  if (!value) return ''
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? '' : date.toLocaleDateString('en-US', { dateStyle: 'medium' })
}

// Server validation arrives as { errors: [...] } or { error: "..." }.
export function errorMessage(failure, fallback) {
  const data = failure?.response?.data
  if (Array.isArray(data?.errors) && data.errors.length) return data.errors.join(' ')
  return data?.error || fallback
}

export function mutationErrorMessage(failure) {
  const status = failure?.response?.status
  return status >= 400 && status < 500
    ? errorMessage(failure, 'The change was rejected. Review the details and try again.')
    : "We couldn't confirm the result. Refresh to check before trying again."
}

// Shared read for the admin list screens. Each read is fenced to the current
// account and visit; a stale response never replaces newer rows.
export function useAdminList(identity, resourcePath, endpoint, params, { enabled = true, preserveFilters = false } = {}) {
  const { beginRequest } = usePlatformRequests(identity, resourcePath)
  const generation = useRef(0)
  const pending = useRef(null)
  const [state, setState] = useState({ data: null, loading: enabled, error: '' })
  const filterOptions = useRef(null)
  const key = JSON.stringify(params)

  const load = useCallback(() => {
    if (!enabled) return
    const request = beginRequest()
    if (!request) return
    pending.current?.abort()
    pending.current = request
    const read = ++generation.current
    const active = () => request.current() && read === generation.current
    setState(previous => ({ ...previous, loading: true, error: '' }))
    apiClient.get(endpoint, { ...request.config, params: { ...JSON.parse(key), ...(preserveFilters && !filterOptions.current ? { include_filters: true } : {}) } })
      .then(response => {
        if (!active()) return
        if (response.data.filters) filterOptions.current = response.data.filters
        setState(previous => ({ data: preserveFilters && !response.data.filters
          ? { ...response.data, filters: filterOptions.current || previous.data?.filters } : response.data, loading: false, error: '' }))
      })
      .catch(failure => {
        if (!active() || request.handleError(failure)) return
        setState(previous => ({ ...previous, loading: false, error: 'This list could not be loaded. Your filters have been kept.' }))
      })
      .finally(() => request.release())
  }, [beginRequest, endpoint, key, enabled, preserveFilters])

  useEffect(() => { load(); return () => pending.current?.abort() }, [load])
  return { ...state, reload: load, beginRequest }
}

// Filters live in the URL so a link from another screen (an event, an order)
// opens the list already narrowed, and Back restores it.
export function readFilters(searchParams, names) {
  return Object.fromEntries(names.map(name => [name, searchParams.get(name) || '']))
}

export function compactParams(filters) {
  return Object.fromEntries(Object.entries(filters).filter(([, value]) => value !== '' && value != null))
}

export const statusTone = {
  pending: 'bg-amber-50 text-amber-900 ring-amber-200',
  processing: 'bg-amber-50 text-amber-900 ring-amber-200',
  held: 'bg-amber-50 text-amber-900 ring-amber-200',
  open: 'bg-amber-50 text-amber-900 ring-amber-200',
  paid: 'bg-emerald-50 text-emerald-800 ring-emerald-200',
  won: 'bg-emerald-50 text-emerald-800 ring-emerald-200',
  posted: 'bg-emerald-50 text-emerald-800 ring-emerald-200',
  failed: 'bg-red-50 text-red-800 ring-red-200',
  lost: 'bg-red-50 text-red-800 ring-red-200',
  reversed: 'bg-neutral-100 text-neutral-700 ring-neutral-200',
}

// Table cells become labelled rows below md, so lists stay readable on a
// phone without sideways scrolling, and stay real tables for screen readers.
export const foldTable = 'w-full text-sm [&_thead]:hidden md:[&_thead]:table-header-group'
export const foldRow = 'block border-b border-neutral-100 px-4 py-3 last:border-b-0 md:table-row md:p-0'
export const foldCell = 'flex gap-3 py-1 before:w-28 before:shrink-0 before:text-xs before:font-medium before:text-content-muted before:content-[attr(data-label)] md:table-cell md:px-3 md:py-3 md:align-top md:before:content-none'

// Fields whose value differs between before and after. Entries that only
// record an "after" snapshot (creations) list every recorded field.
export function auditChanges(before = {}, after = {}) {
  const keys = [...new Set([...Object.keys(before || {}), ...Object.keys(after || {})])]
  return keys.filter(key => JSON.stringify(before?.[key]) !== JSON.stringify(after?.[key]))
    .map(key => ({ key, before: before?.[key], after: after?.[key] }))
}

export const POLICY_HOLD_SCOPES = {
  sales: { label: 'Pause sales', badge: 'Sales paused by HåfaPass', body: 'The event page stays up, but nobody can buy tickets online or at the door.' },
  hidden: { label: 'Hide the event', badge: 'Hidden by HåfaPass', body: 'Removes the event page and listings, and stops all sales.' },
}
