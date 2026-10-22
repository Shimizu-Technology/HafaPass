import { useTranslation } from 'react-i18next'
import { languageFor } from '../utils/locale'

// The language event text is requested in. Pages that show event text from
// the API add it to their fetch dependencies so switching language reloads it.
export default function useContentLanguage() {
  const { i18n } = useTranslation()
  return languageFor(i18n?.resolvedLanguage || i18n?.language).code
}
