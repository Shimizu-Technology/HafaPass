import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, it } from 'vitest'
import { I18nextProvider } from 'react-i18next'
import i18next from 'i18next'
import en from '../locales/en.json'
import MachineTranslationNotice from './MachineTranslationNotice'
import PolicyLanguageNotice from './PolicyLanguageNotice'
import useTranslatedContent from '../hooks/useTranslatedContent'
import { configureEnabledLanguages } from '../utils/locale'

async function setup(lng = 'en') {
  const i18n = i18next.createInstance()
  await i18n.init({ lng, fallbackLng: 'en', resources: { en: { translation: en } } })
  return i18n
}

function EventText({ event }) {
  const content = useTranslatedContent(event)
  return <div><h1>{content.title}</h1><p>{content.description}</p>{content.notice && <MachineTranslationNotice {...content.notice} />}</div>
}

it('labels machine-translated event text and switches to the original and back', async () => {
  const user = userEvent.setup()
  const event = {
    title: '선셋 피에스타', description: '의자를 가져오세요', machine_translated: true,
    original_content: { title: 'Sunset Fiesta', description: 'Bring a chair' },
  }
  render(<I18nextProvider i18n={await setup('ko')}><EventText event={event} /></I18nextProvider>)

  expect(screen.getByRole('heading')).toHaveTextContent('선셋 피에스타')
  expect(screen.getByText('Translated automatically')).toBeInTheDocument()
  await user.click(screen.getByRole('button', { name: 'Show original' }))
  expect(screen.getByRole('heading')).toHaveTextContent('Sunset Fiesta')
  expect(screen.getByText('Bring a chair')).toBeInTheDocument()
  expect(screen.getByRole('button', { name: 'Show translation' })).toHaveAttribute('aria-pressed', 'true')
  await user.click(screen.getByRole('button', { name: 'Show translation' }))
  expect(screen.getByRole('heading')).toHaveTextContent('선셋 피에스타')
})

it('shows no translation control for original text', async () => {
  render(<I18nextProvider i18n={await setup()}><EventText event={{ title: 'Sunset Fiesta', machine_translated: false }} /></I18nextProvider>)
  expect(screen.queryByRole('button')).not.toBeInTheDocument()
})

it('says the English policy governs only when the app is in another language', async () => {
  const { unmount } = render(<I18nextProvider i18n={await setup('en')}><PolicyLanguageNotice /></I18nextProvider>)
  expect(screen.queryByRole('note')).not.toBeInTheDocument()
  unmount()
  configureEnabledLanguages('ja')
  render(<I18nextProvider i18n={await setup('ja')}><PolicyLanguageNotice /></I18nextProvider>)
  expect(screen.getByRole('note')).toHaveTextContent('The English version governs')
  configureEnabledLanguages('en')
})
