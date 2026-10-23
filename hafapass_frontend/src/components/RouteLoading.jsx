import { useTranslation } from 'react-i18next'

export default function RouteLoading() {
  const { t } = useTranslation()
  return <div className="route-loading grid place-items-center" role="status" aria-label={t('buyer.layout.loading')}>
    <span className="font-display text-3xl font-bold text-brand-700">HåfaPass</span>
  </div>
}
