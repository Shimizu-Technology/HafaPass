import { beforeEach, expect, it } from 'vitest'
import { clearUploadRecovery, forgetUploadToken } from './uploadRecovery'

beforeEach(() => window.sessionStorage.clear())

it('clears only the signed-out owner’s upload credentials', () => {
  window.sessionStorage.setItem('hafapass:upload-completion:old:org-a:profile:hash', 'old-token')
  window.sessionStorage.setItem('hafapass:upload-completion:new:org-a:profile:hash', 'new-token')
  window.sessionStorage.setItem('unrelated', 'keep')
  clearUploadRecovery('old')
  expect(window.sessionStorage.length).toBe(2)
  expect(window.sessionStorage.getItem('hafapass:upload-completion:new:org-a:profile:hash')).toBe('new-token')
})

it('does not let an old response clear a replacement recovery credential', () => {
  window.sessionStorage.setItem('recovery', 'replacement')
  forgetUploadToken('recovery', 'old-token')
  expect(window.sessionStorage.getItem('recovery')).toBe('replacement')
  forgetUploadToken('recovery', 'replacement')
  expect(window.sessionStorage.getItem('recovery')).toBeNull()
})
