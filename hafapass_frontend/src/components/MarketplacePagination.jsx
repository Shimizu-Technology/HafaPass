import { useTranslation } from 'react-i18next'
import { ChevronLeft, ChevronRight } from 'lucide-react'

export default function MarketplacePagination({ meta, page, onPage }) {
  const { t } = useTranslation()
  if (!meta || meta.total_pages <= 1) return null

  return <nav aria-label={t('buyer.MarketplacePagination.resultPages')} className="mt-10 flex items-center justify-center gap-4">
    <button type="button" onClick={() => onPage(page - 1)} disabled={page <= 1} className="btn-secondary inline-flex items-center gap-1 disabled:opacity-40">
      <ChevronLeft className="h-4 w-4" />{t('buyer.MarketplacePagination.previous')}</button>
    <span className="text-sm text-neutral-600">{t('buyer.MarketplacePagination.pageOf', { page: meta.current_page, total: meta.total_pages })}</span>
    <button type="button" onClick={() => onPage(page + 1)} disabled={page >= meta.total_pages} className="btn-secondary inline-flex items-center gap-1 disabled:opacity-40">{t('buyer.MarketplacePagination.next')}<ChevronRight className="h-4 w-4" />
    </button>
  </nav>
}
