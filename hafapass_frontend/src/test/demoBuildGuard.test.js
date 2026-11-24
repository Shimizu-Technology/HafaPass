import process from 'node:process'
import { execFileSync } from 'node:child_process'
import { expect, it } from 'vitest'
for (const context of ['production', '', 'branch-deploy']) {
  it(`refuses a demo build in ${context || 'an ordinary production build'}`, () => {
    let output = ''
    try {
      execFileSync(process.execPath, ['node_modules/vite/bin/vite.js', 'build'], { cwd: process.cwd(), env: { ...process.env, CONTEXT: context, VITE_HAFAPASS_DEMO_DATA: '1' }, stdio: 'pipe' })
    } catch (error) { output = String(error.stderr) }
    expect(output).toContain('Demo data can only be built in the deploy-preview context; production is forbidden')
  })
}
