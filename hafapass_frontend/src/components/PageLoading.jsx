import { useInRouterContext, useLocation } from 'react-router-dom'
import HafaPassMark from './HafaPassMark'
import { isDarkHeaderPath, isDarkPagePath } from '../utils/headerTheme'

// A plain stand-in for the navigation while account state is still unknown:
// the brand and a link home, no account-dependent links or menus.
function StaticHeader({ dark }) {
  return <header className={`app-nav border-b ${dark ? 'border-transparent bg-brand-950' : 'border-neutral-200 bg-white'}`}>
    <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
      <div className="flex min-h-16 items-center py-2">
        <a href="/" aria-label="HåfaPass" className="flex min-h-11 items-center gap-2.5">
          <span className="flex h-9 w-9 items-center justify-center rounded-xl bg-brand-700"><HafaPassMark className="h-5 w-5 text-white" /></span>
          <span className={`text-xl font-bold tracking-tight ${dark ? 'text-white' : 'text-neutral-900'}`}>Håfa<span className={dark ? 'text-brand-400' : 'text-brand-500'}>Pass</span></span>
        </a>
      </div>
    </div>
  </header>
}

function PageLoadingView({ label, message, className = 'route-loading', header = false, darkHeader, darkPage }) {
  return <>
    {header && <StaticHeader dark={darkHeader} />}
    <div className={`${className} grid place-items-center px-4 ${darkPage ? 'bg-brand-950' : ''}`} role="status" aria-label={message ? undefined : label}>
      <div className="text-center">
        <span aria-hidden={message ? 'true' : undefined} className={`page-loading-mark font-display text-3xl font-bold ${darkPage ? 'text-white' : 'text-brand-700'}`}>HåfaPass</span>
        {message && <p className={`mt-3 text-base font-medium ${darkPage ? 'text-brand-100' : 'text-content-muted'}`}>{message}</p>}
      </div>
    </div>
  </>
}

function RoutedPageLoading(props) {
  const { pathname } = useLocation()
  return <PageLoadingView {...props} darkHeader={isDarkHeaderPath(pathname)} darkPage={isDarkPagePath(pathname)} />
}

// The one whole-route loading state: the HåfaPass wordmark on the route's own
// page color, so loading never flashes a different background. `label` names
// a silent status; `message` is shown under the wordmark instead.
export default function PageLoading(props) {
  return useInRouterContext() ? <RoutedPageLoading {...props} /> : <PageLoadingView {...props} />
}
