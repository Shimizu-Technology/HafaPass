import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import RoleComparison from './RoleComparison'
import roleMatrix from '../../generated/roleMatrix.json'
import { ORGANIZATION_ROLES, roleLabel, EVENT_ASSIGNMENT_DESCRIPTION, OFFLINE_SCANNER_ACCESS_NOTE } from '../../utils/roles'

describe('RoleComparison', () => {
  it('shares backend-generated labels with every frontend role picker', () => {
    expect(Object.keys(ORGANIZATION_ROLES)).toEqual(['owner', 'manager', 'finance', 'marketer', 'box_office', 'scanner'])
    for (const { key, label } of roleMatrix.roles) {
      expect(roleLabel(key)).toBe(label)
      expect(ORGANIZATION_ROLES[key].description).toBeTruthy()
    }
    expect(EVENT_ASSIGNMENT_DESCRIPTION).toBe(roleMatrix.notes.assignments)
    expect(OFFLINE_SCANNER_ACCESS_NOTE).toBe(roleMatrix.notes.offline)
  })

  it('renders the generated capability values under each ordered desktop column', () => {
    render(<RoleComparison onClose={vi.fn()} />)
    const table = screen.getByRole('table', { name: 'Organization role permissions' })
    expect(within(table).getAllByRole('columnheader').map(cell => cell.textContent)).toEqual([
      'What they can do', 'Owner', 'Manager', 'Finance', 'Marketer', 'Box office', 'Door scanner',
    ])
    const rows = within(table).getAllByRole('row').slice(1)
    expect(rows).toHaveLength(23)
    roleMatrix.rows.forEach((row, index) => {
      expect(within(rows[index]).getByRole('rowheader')).toHaveTextContent(row.label)
      expect(within(rows[index]).getAllByRole('cell').map(cell => cell.textContent)).toEqual(roleMatrix.roles.map(role => row.values[role.key]))
    })
  })

  it('provides stacked comparisons with every capability and the same restrictions for phones', () => {
    render(<RoleComparison onClose={vi.fn()} />)
    const cards = screen.getByLabelText('Stacked role comparison').querySelectorAll('section')
    expect(cards).toHaveLength(23)
    for (const [index, card] of [...cards].entries()) {
      expect(within(card).getByRole('heading')).toHaveTextContent(roleMatrix.rows[index].label)
      expect([...card.querySelectorAll('dt')].map(item => item.textContent)).toEqual(roleMatrix.roles.map(role => role.label))
      expect([...card.querySelectorAll('dd')].map(item => item.textContent)).toEqual(roleMatrix.roles.map(role => roleMatrix.rows[index].values[role.key]))
    }
    const notes = within(screen.getByRole('list', { name: 'Role access notes' }))
    expect(notes.getByText("Managers can't cancel events or move money.")).toBeInTheDocument()
    expect(notes.getByText(OFFLINE_SCANNER_ACCESS_NOTE)).toBeInTheDocument()
    expect(notes.getByText(EVENT_ASSIGNMENT_DESCRIPTION)).toBeInTheDocument()
  })

  it('closes with Escape and restores focus to its trigger', async () => {
    const user = userEvent.setup()
    const close = vi.fn()
    const trigger = document.createElement('button')
    trigger.textContent = 'Open comparison'
    document.body.append(trigger)
    trigger.focus()
    const view = render(<RoleComparison onClose={close} />)
    expect(screen.getByRole('button', { name: 'Close' })).toHaveFocus()
    await user.tab()
    expect(screen.getByRole('button', { name: 'Close' })).toHaveFocus()
    await user.tab({ shift: true })
    expect(screen.getByRole('button', { name: 'Close' })).toHaveFocus()
    await user.keyboard('{Escape}')
    expect(close).toHaveBeenCalledOnce()
    view.unmount()
    expect(trigger).toHaveFocus()
    trigger.remove()
  })
})
