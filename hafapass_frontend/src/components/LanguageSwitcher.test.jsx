import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, it } from 'vitest'
import { I18nextProvider } from 'react-i18next'
import i18next from 'i18next'
import LanguageSwitcher from './LanguageSwitcher'

async function renderSwitcher(lng = 'en') {
  const i18n = i18next.createInstance()
  await i18n.init({ lng, resources: {} })
  render(<I18nextProvider i18n={i18n}><LanguageSwitcher /><button>Outside</button></I18nextProvider>)
  return i18n
}

it('exposes selection and expanded state, supports arrows/Escape, and returns focus on selection', async () => {
  const i18n = await renderSwitcher()
  const user = userEvent.setup()
  const trigger = screen.getByRole('button', { name: 'Change language, English' })
  await user.click(trigger)
  expect(trigger).toHaveAttribute('aria-expanded', 'true')
  expect(screen.getByRole('button', { name: 'English' })).toHaveAttribute('aria-pressed', 'true')
  await user.keyboard('{ArrowDown}')
  expect(screen.getByRole('button', { name: 'English' })).toHaveFocus()
  await user.keyboard('{ArrowDown}{Enter}')
  expect(i18n.language).toBe('ko')
  expect(trigger).toHaveFocus()
  expect(trigger).toHaveAttribute('aria-expanded', 'false')
  await user.click(trigger)
  await user.keyboard('{ArrowDown}{Escape}')
  expect(trigger).toHaveFocus()
  expect(trigger).toHaveAttribute('aria-expanded', 'false')
  await user.click(trigger)
  await user.click(screen.getByRole('button', { name: 'Outside' }))
  expect(trigger).toHaveAttribute('aria-expanded', 'false')
  expect(screen.getByRole('button', { name: 'Outside' })).toHaveFocus()
})

it('offers the six buyer languages by native name and hides CHamoru until it is translated', async () => {
  const user = userEvent.setup()
  await renderSwitcher('zh-Hant')
  const trigger = screen.getByRole('button', { name: 'Change language, 繁體中文' })
  await user.click(trigger)

  const options = within(screen.getByRole('group', { name: 'Available languages' })).getAllByRole('button')
  expect(options.map(option => option.getAttribute('data-language'))).toEqual(['en', 'ko', 'ja', 'zh-Hant', 'zh', 'tl'])
  expect(options.map(option => option.textContent)).toEqual([
    'English', '한국어Korean', '日本語Japanese', '繁體中文Chinese (Traditional)', '简体中文Chinese (Simplified)', 'Filipino',
  ])
  expect(options[3]).toHaveAttribute('aria-pressed', 'true')
  expect(options[4]).toHaveAttribute('lang', 'zh-Hans')
  expect(screen.queryByText('CHamoru')).not.toBeInTheDocument()

  await user.keyboard('{End}{Enter}')
  expect(screen.getByRole('button', { name: 'Change language, Filipino' })).toBeInTheDocument()
})
