import { describe, expect, it } from 'vitest'
import { resolveAppVersion, versionLabel } from './version.js'

describe('versionLabel', () => {
  it('hiển thị phiên bản người dùng chọn', () => {
    expect(versionLabel('1.4.2')).toBe('Phiên bản 1.4.2')
  })
})

describe('resolveAppVersion', () => {
  it('lấy APP_VERSION từ môi trường build', () => {
    expect(resolveAppVersion({ APP_VERSION: '1.4.2' })).toBe('1.4.2')
  })

  it('dùng latest khi người dùng chưa chỉ định tag', () => {
    expect(resolveAppVersion({})).toBe('latest')
  })
})
