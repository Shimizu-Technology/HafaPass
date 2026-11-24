import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import apiClient from '../api/client'

export default function EmailPreferencesLink() {
  const { t } = useTranslation()
  const [error, setError] = useState(false)
  return <div className="my-4"><button className="btn-secondary" onClick={async () => {
    try { const { data } = await apiClient.get('/email_preferences/account'); window.location.assign(data.url) }
    catch { setError(true) }
  }}>{t('emailBase.preferences')}</button>{error && <p role="alert">{t('emailBase.error')}</p>}</div>
}
