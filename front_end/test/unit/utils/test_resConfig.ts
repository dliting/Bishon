import { describe, it, expect } from 'vitest'
import checkResStatus from '@/services/ResConfig'

describe('ResConfig', () => {
  it('isSuccess returns true for 200', () => {
    expect(checkResStatus.isSuccess(200)).toBe(true)
  })
  it('isSuccess returns false for 404', () => {
    expect(checkResStatus.isSuccess(404)).toBe(false)
  })
  it('noLogin returns true for 401', () => {
    expect(checkResStatus.noLogin(401)).toBe(true)
  })
  it('noPerssion returns true for 403', () => {
    expect(checkResStatus.noPerssion(403)).toBe(true)
  })
  it('noLogin returns false for 200', () => {
    expect(checkResStatus.noLogin(200)).toBe(false)
  })
  it('isSuccess handles string code', () => {
    expect(checkResStatus.isSuccess('200')).toBe(true)
  })
})
