import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { expect, it } from 'vitest'
import { I18nextProvider } from 'react-i18next'
import i18next from 'i18next'
import LanguageSwitcher from './LanguageSwitcher'

it('exposes selection and expanded state, supports arrows/Escape, and returns focus on selection', async () => {
  const i18n = i18next.createInstance()
  await i18n.init({ lng: 'en', resources: {} })
  const user = userEvent.setup()
  render(<I18nextProvider i18n={i18n}><LanguageSwitcher /><button>Outside</button></I18nextProvider>)
  const trigger = screen.getByRole('button', { name: 'Change language, English' })
  await user.click(trigger)
  expect(trigger).toHaveAttribute('aria-expanded', 'true')
  expect(screen.getByRole('button', { name: 'EN English' })).toHaveAttribute('aria-pressed', 'true')
  await user.keyboard('{ArrowDown}')
  expect(screen.getByRole('button', { name: 'EN English' })).toHaveFocus()
  await user.keyboard('{ArrowDown}{Enter}')
  expect(i18n.language).toBe('ch')
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
