import { useEffect, useState } from 'react'
import { useLocation, useNavigate, useParams } from 'react-router-dom'
import { Loader2 } from 'lucide-react'
import apiClient from '../api/client'
import { anonymousId, saveAttribution } from '../utils/marketplaceAttribution'

export default function DistributionRedirectPage() {
  const { code } = useParams()
  const navigate = useNavigate()
  const location = useLocation()
  const [error, setError] = useState(null)

  useEffect(() => {
    const endpoint = location.pathname.startsWith('/refer/') ? 'event_referrals' : 'distribution_links'
    apiClient.get(`/${endpoint}/${encodeURIComponent(code)}`, { params: { anonymous_id: anonymousId() } })
      .then(({ data }) => {
        saveAttribution(data.attribution)
        const attributionKey = data.attribution.event_referral_code ? 'event_referral_code' : 'distribution_code'
        navigate(`/events/${data.event_slug}?${attributionKey}=${encodeURIComponent(code)}`, { replace: true })
      })
      .catch(() => setError('This partner link is unavailable or has expired.'))
  }, [code, location.pathname, navigate])

  return <div className="mx-auto max-w-xl px-4 py-24 text-center">
    {error ? <><p className="text-red-600">{error}</p><button className="btn-primary mt-4" onClick={() => navigate('/events')}>Browse events</button></> :
      <><Loader2 className="mx-auto h-8 w-8 animate-spin text-brand-500" /><p className="mt-3 text-neutral-500">Opening your event…</p></>}
  </div>
}
