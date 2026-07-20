import { describe, expect, it } from 'vitest'
import { monitoringPath } from './client'

describe('monitoringPath', () => {
  it('removes query data and opaque identifiers from monitored paths', () => {
    expect(monitoringPath('/orders/123/confirmation?email=guest@example.com'))
      .toBe('/orders/:id/confirmation')
    expect(monitoringPath('/tickets/4c2aa90e-1f34-4e87-847e-f705a0c7c782'))
      .toBe('/tickets/:id')
  })
})
