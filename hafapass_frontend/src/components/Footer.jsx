import { ChevronDown, ExternalLink } from 'lucide-react'
import { guamPhotos } from '../config/photoCredits'
import HafaPassMark from './HafaPassMark'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useSupportContact } from '../utils/supportContact'
import SupportLink from './SupportLink'

export default function Footer() {
  const { t } = useTranslation()
  const support = useSupportContact()

  return (
    <footer className="bg-brand-950 text-content-inverse-muted py-8 sm:py-12 relative">
      <div className="max-w-6xl mx-auto px-6 lg:px-8 relative z-[2]">
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-x-6 gap-y-4 sm:gap-8 mb-6 sm:mb-8">
          {/* Brand */}
          <div className="col-span-2 lg:col-span-1">
            <div className="flex items-center gap-2 mb-3">
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
            <h3 className="text-base font-semibold text-neutral-200 mb-2">{t('footer.platform')}</h3>
            <ul className="space-y-1">
              <li><Link to="/events" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.browseEvents')}</Link></li>
              <li><Link to="/host" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.forOrganizers')}</Link></li>
              <li><Link to="/sign-in" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.signIn')}</Link></li>
            </ul>
          </div>

          {/* Help links lead to actual recovery and support, rather than generic social sites. */}
          <div>
            <h3 className="text-base font-semibold text-neutral-200 mb-2">{t('footer.help')}</h3>
            <ul className="space-y-1">
              <li><Link to="/orders/recover" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.findTickets')}</Link></li>
              <li><a href={support.mailto()} className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.contactSupport')}</a></li>
              {support.tel && <li><a href={support.tel} className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.callSupport', { phone: support.phone })}</a></li>}
            </ul>
          </div>
          {/* Company */}
          <div className="col-span-2 lg:col-span-1">
            <h3 className="text-base font-semibold text-neutral-200 mb-2">{t('footer.company')}</h3>
            <ul className="space-y-1">
              <li><a href="https://shimizu-technology.com" target="_blank" rel="noopener noreferrer" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.companyName')}<ExternalLink aria-hidden="true" className="ml-1.5 h-3.5 w-3.5 shrink-0" /><span className="sr-only">{t('footer.opensNewTab')}</span></a></li>
            </ul>
          </div>

          <div className="col-span-2 border-t border-white/10 pt-2 lg:col-span-4">
            <ul className="flex flex-wrap gap-x-6">
              <li><Link to="/policies/privacy" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('footer.privacy')}</Link></li>
              <li><Link to="/policies/buyer-terms" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.buyerTerms')}</Link></li>
              <li><Link to="/policies/refunds" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.refunds')}</Link></li>
              <li className="hidden md:list-item"><Link to="/policies/organizer-agreement" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.organizerAgreement')}</Link></li>
              <li className="hidden md:list-item"><Link to="/policies/accessibility" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.accessibility')}</Link></li>
              <li className="hidden md:list-item"><Link to="/policies/cookies" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.cookies')}</Link></li>
            </ul>
            <details className="group md:hidden">
              <summary className="flex min-h-11 cursor-pointer list-none items-center justify-between gap-4 rounded text-sm font-semibold text-neutral-300 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white [&::-webkit-details-marker]:hidden">
                {t('buyerDiscovery.policy.otherPolicies')}
                <ChevronDown aria-hidden="true" className="h-4 w-4 shrink-0 group-open:rotate-180" />
              </summary>
              <ul className="grid grid-cols-2 gap-x-4 pb-2">
              <li><Link to="/policies/organizer-agreement" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.organizerAgreement')}</Link></li>
              <li><Link to="/policies/accessibility" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.accessibility')}</Link></li>
              <li><Link to="/policies/cookies" className="inline-flex min-h-11 items-center rounded text-sm text-content-inverse-muted hover:text-content-inverse transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{t('buyer.Footer.cookies')}</Link></li>
              </ul>
            </details>
          </div>
        </div>

        {Object.keys(guamPhotos).length > 0 && <details className="mb-5 max-w-3xl">
          <summary className="inline-flex min-h-11 cursor-pointer items-center gap-2 rounded text-sm font-medium text-content-inverse-muted underline underline-offset-4 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">
            {t('footer.photoCredits')}
          </summary>
          <p className="mt-2 text-sm leading-relaxed">{t('footer.photoChanges')}</p>
          <ul className="mt-3 space-y-2 text-sm leading-relaxed">
            {Object.values(guamPhotos).map(photo => <li key={photo.file} className="break-words">
              <a href={photo.sourceUrl} target="_blank" rel="noopener noreferrer" className="rounded underline underline-offset-4 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{photo.title}</a>
              {' '}{t('footer.photoCreditBy', { author: photo.author })}{' · '}
              <a href={photo.licenseUrl} target="_blank" rel="noopener noreferrer" className="rounded underline underline-offset-4 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-white">{photo.license}</a>
            </li>)}
          </ul>
        </details>}

        {/* Divider + Copyright */}
        <div className="border-t border-white/10 pt-4 flex flex-col sm:flex-row items-center justify-between gap-2 text-center sm:text-left">
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
