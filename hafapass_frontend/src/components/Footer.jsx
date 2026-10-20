import HafaPassMark from './HafaPassMark'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useSupportContact } from '../utils/supportContact'
import SupportLink from './SupportLink'

export default function Footer() {
  const { t } = useTranslation()
  const support = useSupportContact()

  return (
    <footer className="bg-brand-950 text-content-inverse-muted py-14 relative">
      <div className="max-w-6xl mx-auto px-6 lg:px-8 relative z-[2]">
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-10 mb-10">
          {/* Brand */}
          <div className="lg:col-span-1">
            <div className="flex items-center gap-2 mb-4">
              <div className="w-8 h-8 rounded-lg bg-brand-500/20 flex items-center justify-center">
                <HafaPassMark className="h-5 w-5 text-brand-300" />
              </div>
              <span className="text-base font-bold text-neutral-200 tracking-tight">HåfaPass</span>
            </div>
            <p className="text-sm text-content-inverse-muted leading-relaxed">
              {t('footer.tagline')}
            </p>
          </div>

          {/* Platform */}
          <div>
            <h3 className="text-sm font-semibold text-neutral-300 uppercase tracking-wider mb-4">{t('footer.platform')}</h3>
            <ul className="space-y-1">
              <li><Link to="/events" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.browseEvents')}</Link></li>
              <li><Link to="/host" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.forOrganizers')}</Link></li>
              <li><Link to="/sign-in" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.signIn')}</Link></li>
            </ul>
          </div>

          {/* Company */}
          <div>
            <h3 className="text-sm font-semibold text-neutral-300 uppercase tracking-wider mb-4">{t('footer.company')}</h3>
            <ul className="space-y-1">
              <li><a href="https://shimizu-technology.com" target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.about')}</a></li>
              <li><a href={support.mailto()} className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.contact')}</a></li>
              <li><Link to="/policies/privacy" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.privacy')}</Link></li>
              <li><Link to="/policies/buyer-terms" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">Buyer Terms</Link></li>
              <li><Link to="/policies/refunds" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">Refunds</Link></li>
            </ul>
          </div>

          {/* Help links lead to actual recovery and support, rather than generic social sites. */}
          <div>
            <h3 className="text-sm font-semibold text-neutral-300 uppercase tracking-wider mb-4">{t('footer.help')}</h3>
            <ul className="space-y-1">
              <li><Link to="/orders/recover" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.findTickets')}</Link></li>
              <li><a href={support.mailto()} className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.contactSupport')}</a></li>
              {support.tel && <li><a href={support.tel} className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.callSupport', { phone: support.phone })}</a></li>}
            </ul>
          </div>
        </div>

        {/* Divider + Copyright */}
        <div className="border-t border-white/5 pt-6 flex flex-col sm:flex-row items-center justify-between gap-3">
          <p className="text-xs text-content-inverse-muted">
            &copy; {new Date().getFullYear()} {t('footer.copyright')}
          </p>
          <p className="text-xs text-content-inverse-muted">
            {t('footer.madeWith')}
          </p>
        </div>
      </div>
    </footer>
  )
}

// Workspace pages keep a single quiet line instead of the marketing footer.
// Organizer/admin screens never fall back to buyer ticket recovery.
export function WorkspaceFooter() {
  const { t } = useTranslation()
  return (
    <footer className="border-t border-neutral-200 bg-white">
      <div className="mx-auto flex max-w-6xl flex-col gap-1 px-4 py-4 text-xs text-neutral-500 sm:flex-row sm:items-center sm:justify-between sm:px-6 lg:px-8">
        <p>&copy; {new Date().getFullYear()} {t('footer.copyright')}</p>
        <SupportLink className="inline-flex min-h-11 items-center self-start font-medium text-neutral-600 hover:text-neutral-900 sm:self-auto">{t('footer.contactSupport')}</SupportLink>
      </div>
    </footer>
  )
}
