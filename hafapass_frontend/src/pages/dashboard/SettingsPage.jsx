import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'

const MODES = [
 {
  value: 'simulate',
  label: 'Simulate',
  description: 'No real charges. Orders auto-complete for development/testing.',
  color: 'border-amber-300 bg-amber-50',
  activeColor: 'border-amber-500 bg-amber-50 ring-2 ring-amber-500',
  dot: 'bg-amber-500',
 },
 {
  value: 'test',
  label: 'Test (Stripe Sandbox)',
  description: 'Real Stripe API with test keys. Use test card 4242 4242 4242 4242.',
  color: 'border-brand-300 bg-brand-50',
  activeColor: 'border-brand-500 bg-brand-50 ring-2 ',
  dot: 'bg-brand-500',
 },
 {
  value: 'live',
  label: 'Live (Real Money)',
  description: 'Production Stripe. Real charges will be made to real cards.',
  color: 'border-green-300 bg-green-50',
  activeColor: 'border-green-500 bg-green-50 ring-2 ring-green-500',
  dot: 'bg-green-500',
 },
]

export default function SettingsPage() {
 const [settings, setSettings] = useState(null)
 const [loading, setLoading] = useState(true)
 const [saving, setSaving] = useState(false)
 const [error, setError] = useState(null)
 const [success, setSuccess] = useState(null)

 useEffect(() => {
  apiClient.get('/admin/settings')
   .then(res => {
    setSettings(res.data)
    setLoading(false)
   })
   .catch(err => {
    const msg = err.response?.status === 403
     ? 'Admin access required.'
     : 'Failed to load settings.'
    setError(msg)
    setLoading(false)
   })
 }, [])

 const handleModeChange = async (newMode) => {
  if (!settings || newMode === settings.payment_mode) return

  // Client-side safety checks
  if (newMode === 'test' && !settings.stripe_test_configured) {
   setError('Cannot enable test mode \u2014 no Stripe test keys configured on the server.')
   return
  }
  if (newMode === 'live' && !settings.stripe_live_configured) {
   setError('Cannot enable live mode \u2014 no Stripe live keys configured on the server.')
   return
  }

  // Confirm live mode
  if (newMode === 'live') {
   const confirmed = window.confirm(
    'Are you sure you want to enable LIVE mode?\n\n' +
    'Real credit cards will be charged real money. ' +
    'Make sure everything is tested first.'
   )
   if (!confirmed) return
  }

  setSaving(true)
  setError(null)
  setSuccess(null)

  try {
   const res = await apiClient.patch('/admin/settings', { payment_mode: newMode })
   setSettings(res.data)
   const labels = { simulate: 'Simulate', test: 'Test (Stripe Sandbox)', live: 'Live' }
   setSuccess(`Payment mode changed to ${labels[newMode]}`)
   setTimeout(() => setSuccess(null), 4000)
  } catch (err) {
   const msg = err.response?.data?.error || 'Failed to update settings.'
   setError(msg)
  } finally {
   setSaving(false)
  }
 }

 if (loading) {
  return (
   <div className="flex justify-center py-16">
    <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-brand-600"></div>
   </div>
  )
 }

 return (
  <div className="max-w-3xl mx-auto px-4 sm:px-6 py-8">
   <div className="flex items-center gap-3 mb-6">
    <Link to="/dashboard" className="text-brand-500 hover:text-brand-700">
     <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 19l-7-7 7-7" />
     </svg>
    </Link>
    <h1 className="text-2xl font-bold text-neutral-900">Settings</h1>
   </div>

   {error && (
    <div className="bg-red-50 border border-red-200 rounded-xl p-4 mb-6">
     <p className="text-red-700 text-sm">{error}</p>
    </div>
   )}

   {success && (
    <div className="bg-green-50 border border-green-200 rounded-xl p-4 mb-6">
     <p className="text-green-700 text-sm">{success}</p>
    </div>
   )}

   {/* Payment Mode Section */}
   <div className="bg-white border border-neutral-200 rounded-xl shadow-sm p-6 mb-6">
    <h2 className="text-lg font-semibold text-neutral-900 mb-1">Payment Mode</h2>
    <p className="text-sm text-neutral-500 mb-6">
     Controls how payments are processed. Switch between simulated, Stripe sandbox, and production.
    </p>

    <div className="space-y-3">
     {MODES.map(mode => {
      const isActive = settings?.payment_mode === mode.value
      const isDisabled = saving ||
       (mode.value === 'test' && !settings?.stripe_test_configured) ||
       (mode.value === 'live' && !settings?.stripe_live_configured)

      return (
       <button
        key={mode.value}
        onClick={() => handleModeChange(mode.value)}
        disabled={isDisabled}
        className={`w-full text-left p-4 rounded-xl border-2 transition-all duration-200 ${
         isActive
          ? mode.activeColor
          : isDisabled
           ? 'border-neutral-200 bg-neutral-50 opacity-50 cursor-not-allowed'
           : `${mode.color} hover:shadow-sm cursor-pointer`
        }`}
       >
        <div className="flex items-center gap-3">
         <div className={`w-3 h-3 rounded-full ${isActive ? mode.dot : 'bg-neutral-300'}`} />
         <div>
          <p className="font-semibold text-neutral-900">{mode.label}</p>
          <p className="text-sm text-neutral-600 mt-0.5">{mode.description}</p>
          {isDisabled && !isActive && (
           <p className="text-xs text-red-500 mt-1">
            {mode.value === 'test' ? 'Stripe test keys not configured' : 'Stripe live keys not configured'}
           </p>
          )}
         </div>
         {isActive && (
          <svg className="w-5 h-5 text-green-600 ml-auto flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
           <path fillRule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clipRule="evenodd" />
          </svg>
         )}
        </div>
       </button>
      )
     })}
    </div>

    {saving && (
     <p className="text-sm text-neutral-500 mt-3 flex items-center gap-2">
      <svg className="animate-spin h-4 w-4" viewBox="0 0 24 24">
       <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
       <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
      </svg>
      Switching payment mode...
     </p>
    )}
   </div>

   {/* Platform Info Section */}
   {settings && (
    <div className="bg-white border border-neutral-200 rounded-xl shadow-sm p-6">
     <h2 className="text-lg font-semibold text-neutral-900 mb-4">Platform Info</h2>
     <div className="grid grid-cols-2 gap-4 text-sm">
      <div>
       <p className="text-neutral-500">Platform Name</p>
       <p className="text-neutral-900 font-medium">{settings.platform_name}</p>
      </div>
      <div>
       <p className="text-neutral-500">Contact Email</p>
       <p className="text-neutral-900 font-medium">{settings.platform_email || '\u2014'}</p>
      </div>
      <div>
       <p className="text-neutral-500">Service Fee</p>
       <p className="text-neutral-900 font-medium">{settings.service_fee_percent}% + ${(settings.service_fee_flat_cents / 100).toFixed(2)}/ticket</p>
      </div>
      <div>
       <p className="text-neutral-500">Stripe Keys</p>
       <p className="text-neutral-900 font-medium">
        Test: {settings.stripe_test_configured ? '\u2705' : '\u274c'}
        {' '}Live: {settings.stripe_live_configured ? '\u2705' : '\u274c'}
       </p>
      </div>
     </div>
    </div>
   )}
  </div>
 )
}
