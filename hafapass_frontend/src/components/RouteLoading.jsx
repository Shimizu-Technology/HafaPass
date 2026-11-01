import { useTranslation } from 'react-i18next'
import PageLoading from './PageLoading'

export default function RouteLoading() {
  const { t } = useTranslation()
  return <PageLoading label={t('buyer.layout.loading')} />
}
