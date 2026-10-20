import AdminAccessRecovery from '../../components/AdminAccessRecovery'
import { usePlatformIdentity, usePlatformVisit } from '../../hooks/usePlatformContext'

// The same account/visit fence every admin page uses: a new account, revoked
// authority or a fresh visit remounts the session and drops its private state.
export default function AdminSessionGate({ resourcePath, Session }) {
  const identity = usePlatformIdentity('admin')
  const visit = usePlatformVisit(resourcePath)
  if (!visit.active) return null
  if (identity.authorityDenied) return <AdminAccessRecovery key={identity.accountKey} identity={identity} />
  if (!identity.ready) return <p role="status">Checking account access…</p>
  return <Session key={`${identity.accountKey}:${visit.generation}`} identity={identity} resourcePath={resourcePath} />
}
