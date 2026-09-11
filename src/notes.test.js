import { describe, expect, it } from 'vitest'
import { resolveAppVersion, versionLabel } from './version.js'

describe('version helpers', () => {
  it('labels a release tag', () => {
    expect(versionLabel('2.0.0')).toBe('Phiên bản 2.0.0')
  })

  it('reads APP_VERSION from the environment', () => {
    expect(resolveAppVersion({ APP_VERSION: '2.0.0' })).toBe('2.0.0')
  })
})
