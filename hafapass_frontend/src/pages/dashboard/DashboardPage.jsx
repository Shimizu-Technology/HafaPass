import { Loader2, Pencil, X, Upload } from 'lucide-react'
import { useState, useEffect, useRef } from 'react'
import { Link } from 'react-router-dom'
import apiClient from '../../api/client'

function OrganizerProfileForm({ onSuccess }) {
 const [businessName, setBusinessName] = useState('')
 const [businessDescription, setBusinessDescription] = useState('')
 const [submitting, setSubmitting] = useState(false)
 const [error, setError] = useState(null)

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!businessName.trim()) {
   setError('Business name is required')
   return
  }
  setSubmitting(true)
  setError(null)
  try {
   await apiClient.post('/organizer_profile', {
    business_name: businessName.trim(),
    business_description: businessDescription.trim()
   })
   onSuccess()
  } catch (err) {
   const msg = err.response?.data?.errors?.[0] || err.response?.data?.error || 'Failed to create profile'
   setError(msg)
  } finally {
   setSubmitting(false)
  }
 }

 return (
  <div className="max-w-lg mx-auto">
   <div className="bg-white rounded-xl shadow-md p-6">
    <h2 className="text-2xl font-bold text-neutral-900 mb-2">Create Your Organizer Profile</h2>
    <p className="text-neutral-600 mb-6">Set up your organizer profile to start creating and managing events on HafaPass.</p>

    {error && (
     <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">
      {error}
     </div>
    )}

    <form onSubmit={handleSubmit} className="space-y-4">
     <div>
      <label htmlFor="business_name" className="block text-sm font-medium text-neutral-700 mb-1">
       Business Name <span className="text-red-500">*</span>
      </label>
      <input
       id="business_name"
       type="text"
       value={businessName}
       onChange={(e) => setBusinessName(e.target.value)}
       className="input"
       placeholder="e.g., Island Nights Promotions"
       disabled={submitting}
      />
     </div>

     <div>
      <label htmlFor="business_description" className="block text-sm font-medium text-neutral-700 mb-1">
       Description
      </label>
      <textarea
       id="business_description"
       value={businessDescription}
       onChange={(e) => setBusinessDescription(e.target.value)}
       rows={3}
       className="input"
       placeholder="Tell attendees about your business..."
       disabled={submitting}
      />
     </div>

     <button
      type="submit"
      disabled={submitting}
      className="btn-primary w-full"
     >
      {submitting ? 'Creating Profile...' : 'Create Organizer Profile'}
     </button>
    </form>
   </div>
  </div>
 )
}

function StatusBadge({ status }) {
 const styles = {
  draft: 'bg-yellow-100 text-yellow-800',
  published: 'bg-green-100 text-green-800',
  cancelled: 'bg-red-100 text-red-800',
  completed: 'bg-neutral-100 text-neutral-800'
 }
 return (
  <span className={`inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium ${styles[status] || 'bg-neutral-100 text-neutral-800'}`}>
   {status.charAt(0).toUpperCase() + status.slice(1)}
  </span>
 )
}

function EventListCard({ event }) {
 const ticketsSold = event.ticket_types
  ? event.ticket_types.reduce((sum, tt) => sum + (tt.quantity_sold || 0), 0)
  : 0

 const formatDate = (dateStr) => {
  if (!dateStr) return ''
  const date = new Date(dateStr)
  return date.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
 }

 return (
  <Link
   to={`/dashboard/events/${event.id}/edit`}
   className="block bg-white rounded-xl shadow-sm border border-neutral-200 hover:shadow-md hover:border-brand-200 transition-all p-4"
  >
   <div className="flex items-start justify-between gap-3">
    <div className="min-w-0 flex-1">
     <h3 className="text-lg font-semibold text-neutral-900 truncate">{event.title}</h3>
     <p className="text-sm text-neutral-500 mt-0.5">
      {formatDate(event.starts_at)} {event.venue_name && `· ${event.venue_name}`}
     </p>
    </div>
    <StatusBadge status={event.status} />
   </div>
   <div className="mt-3 flex items-center gap-4 text-sm text-neutral-600">
    <span className="flex items-center gap-1">
     <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 5v2m0 4v2m0 4v2M5 5a2 2 0 00-2 2v3a2 2 0 110 4v3a2 2 0 002 2h14a2 2 0 002-2v-3a2 2 0 110-4V7a2 2 0 00-2-2H5z" />
     </svg>
     {ticketsSold} sold
    </span>
    {event.category && (
     <span className="text-neutral-400 capitalize">{event.category.replace('_', ' ')}</span>
    )}
   </div>
  </Link>
 )
}

function EditProfileModal({ profile, onClose, onSaved }) {
 const [businessName, setBusinessName] = useState(profile.business_name || '')
 const [description, setDescription] = useState(profile.business_description || '')
 const [logoUrl, setLogoUrl] = useState(profile.logo_url || '')
 const [saving, setSaving] = useState(false)
 const [uploading, setUploading] = useState(false)
 const [error, setError] = useState(null)
 const fileRef = useRef(null)

 const handleLogoUpload = async (file) => {
  if (!file) return
  const ACCEPTED = ['image/jpeg', 'image/png', 'image/webp']
  if (!ACCEPTED.includes(file.type)) { setError('Please upload JPG, PNG, or WebP'); return }
  if (file.size > 5 * 1024 * 1024) { setError('Image must be under 5MB'); return }
  setUploading(true)
  setError(null)
  try {
   const presignRes = await apiClient.post('/uploads/presign', { filename: file.name, content_type: file.type })
   const { url, fields, public_url } = presignRes.data
   if (fields) {
    const fd = new FormData()
    Object.entries(fields).forEach(([k, v]) => fd.append(k, v))
    fd.append('file', file)
    await fetch(url, { method: 'POST', body: fd })
   } else {
    await fetch(url, { method: 'PUT', headers: { 'Content-Type': file.type }, body: file })
   }
   setLogoUrl(public_url || url.split('?')[0])
  } catch {
   setError('Logo upload failed')
  } finally {
   setUploading(false)
  }
 }

 const handleSubmit = async (e) => {
  e.preventDefault()
  if (!businessName.trim()) { setError('Business name is required'); return }
  setSaving(true)
  setError(null)
  try {
   await apiClient.put('/organizer_profile', {
    business_name: businessName.trim(),
    business_description: description.trim(),
    logo_url: logoUrl || null
   })
   onSaved()
  } catch (err) {
   setError(err.response?.data?.errors?.[0] || err.response?.data?.error || 'Failed to update profile')
  } finally {
   setSaving(false)
  }
 }

 return (
  <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 px-4">
   <div className="bg-white rounded-xl shadow-xl max-w-md w-full p-6">
    <div className="flex items-center justify-between mb-4">
     <h3 className="text-lg font-semibold text-neutral-900">Edit Profile</h3>
     <button onClick={onClose} className="p-1 text-neutral-400 hover:text-neutral-600"><X className="w-5 h-5" /></button>
    </div>
    {error && <div className="mb-4 p-3 bg-red-50 border border-red-200 rounded-xl text-red-700 text-sm">{error}</div>}
    <form onSubmit={handleSubmit} className="space-y-4">
     <div>
      <label className="block text-sm font-medium text-neutral-700 mb-1">Logo</label>
      <div className="flex items-center gap-3">
       {logoUrl ? (
        <img src={logoUrl} alt="Logo" className="w-12 h-12 rounded-xl object-cover border border-neutral-200" />
       ) : (
        <div className="w-12 h-12 rounded-xl bg-neutral-100 flex items-center justify-center">
         <Upload className="w-5 h-5 text-neutral-400" />
        </div>
       )}
       <button type="button" onClick={() => fileRef.current?.click()} disabled={uploading} className="text-sm text-brand-500 hover:text-brand-700 font-medium">
        {uploading ? 'Uploading...' : logoUrl ? 'Change' : 'Upload Logo'}
       </button>
       <input ref={fileRef} type="file" accept=".jpg,.jpeg,.png,.webp" className="hidden" onChange={e => handleLogoUpload(e.target.files[0])} />
      </div>
     </div>
     <div>
      <label className="block text-sm font-medium text-neutral-700 mb-1">Business Name <span className="text-red-500">*</span></label>
      <input value={businessName} onChange={e => setBusinessName(e.target.value)} className="input" disabled={saving} />
     </div>
     <div>
      <label className="block text-sm font-medium text-neutral-700 mb-1">Description</label>
      <textarea value={description} onChange={e => setDescription(e.target.value)} rows={3} className="input" disabled={saving} />
     </div>
     <div className="flex gap-3 justify-end">
      <button type="button" onClick={onClose} disabled={saving} className="px-4 py-2 text-sm font-medium text-neutral-700 hover:text-neutral-900">Cancel</button>
      <button type="submit" disabled={saving} className="btn-primary text-sm px-4 py-2">{saving ? 'Saving...' : 'Save'}</button>
     </div>
    </form>
   </div>
  </div>
 )
}

export default function DashboardPage() {
 const [profile, setProfile] = useState(null)
 const [events, setEvents] = useState([])
 const [loading, setLoading] = useState(true)
 const [error, setError] = useState(null)
 const [showEditProfile, setShowEditProfile] = useState(false)

 const fetchDashboard = async () => {
  setLoading(true)
  setError(null)
  try {
   const profileRes = await apiClient.get('/organizer_profile')
   setProfile(profileRes.data)

   const eventsRes = await apiClient.get('/organizer/events')
   // Handle both paginated { events: [...], meta: {...} } and legacy array response
   const eventsData = eventsRes.data.events || eventsRes.data
   setEvents(Array.isArray(eventsData) ? eventsData : [])
  } catch (err) {
   if (err.response?.status === 404) {
    // No organizer profile — show create form
    setProfile(null)
   } else if (err.response?.status === 401) {
    setError('Please sign in to access the dashboard.')
   } else {
    setError('Failed to load dashboard. Please try again.')
   }
  } finally {
   setLoading(false)
  }
 }

 useEffect(() => {
  fetchDashboard()
 }, [])

 if (loading) {
  return (
   <div className="min-h-[60vh] flex items-center justify-center">
    <Loader2 className="w-8 h-8 text-brand-500 animate-spin" />
   </div>
  )
 }

 if (error) {
  return (
   <div className="max-w-2xl mx-auto px-4 py-12">
    <div className="bg-red-50 border border-red-200 rounded-xl p-6 text-center">
     <p className="text-red-700">{error}</p>
     <button
      onClick={fetchDashboard}
      className="mt-4 text-red-600 hover:text-red-800 font-medium underline"
     >
      Try Again
     </button>
    </div>
   </div>
  )
 }

 if (!profile) {
  return (
   <div className="px-4 py-12">
    <OrganizerProfileForm onSuccess={fetchDashboard} />
   </div>
  )
 }

 return (
  <div className="max-w-4xl mx-auto px-4 py-8">
   <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-8">
    <div>
     <div className="flex items-center gap-2">
      <h1 className="text-2xl font-bold text-neutral-900">Welcome, {profile.business_name}</h1>
      <button onClick={() => setShowEditProfile(true)} className="p-1.5 text-neutral-400 hover:text-brand-500 rounded-lg hover:bg-brand-50 transition-colors" title="Edit Profile">
       <Pencil className="w-4 h-4" />
      </button>
     </div>
     <p className="text-neutral-600 mt-1">Manage your events and track ticket sales</p>
    </div>
    <div className="flex items-center gap-3">
     <Link
      to="/dashboard/scanner"
      className="inline-flex items-center justify-center gap-2 bg-brand-500 text-white px-4 py-2.5 min-h-[44px] rounded-xl font-medium hover:bg-brand-600 transition-colors text-sm"
     >
      <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v1m6 11h2m-6 0h-2v4m0-11v3m0 0h.01M12 12h4.01M16 20h4M4 12h4m12 0h.01M5 8h2a1 1 0 001-1V5a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1zm12 0h2a1 1 0 001-1V5a1 1 0 00-1-1h-2a1 1 0 00-1 1v2a1 1 0 001 1zM5 20h2a1 1 0 001-1v-2a1 1 0 00-1-1H5a1 1 0 00-1 1v2a1 1 0 001 1z" />
      </svg>
      Scan Tickets
     </Link>
     <Link
      to="/dashboard/events/new"
      className="inline-flex items-center justify-center gap-2 bg-accent-500 text-white px-4 py-2.5 min-h-[44px] rounded-xl font-medium hover:bg-accent-600 transition-colors text-sm"
     >
      <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
      </svg>
      Create Event
     </Link>
     <Link
      to="/dashboard/settings"
      className="inline-flex items-center justify-center gap-2 bg-neutral-100 text-neutral-700 px-4 py-2.5 min-h-[44px] rounded-xl font-medium hover:bg-neutral-200 transition-colors text-sm border border-neutral-300"
     >
      <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z" />
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
      </svg>
      Settings
     </Link>
    </div>
   </div>

   {showEditProfile && (
    <EditProfileModal
     profile={profile}
     onClose={() => setShowEditProfile(false)}
     onSaved={() => { setShowEditProfile(false); fetchDashboard() }}
    />
   )}

   {events.length === 0 ? (
    <div className="bg-white rounded-xl shadow-sm border border-neutral-200 p-12 text-center">
     <svg className="mx-auto h-12 w-12 text-neutral-400 mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z" />
     </svg>
     <h3 className="text-lg font-medium text-neutral-900 mb-1">No events yet</h3>
     <p className="text-neutral-500 mb-4">Get started by creating your first event</p>
     <Link
      to="/dashboard/events/new"
      className="btn-primary gap-2"
     >
      <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
       <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
      </svg>
      Create Your First Event
     </Link>
    </div>
   ) : (
    <div className="space-y-3">
     {events.map((event) => (
      <EventListCard key={event.id} event={event} />
     ))}
    </div>
   )}
  </div>
 )
}
