import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, it, expect } from 'vitest'
import { useUser } from '@/store/useUser'

describe('useUser store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('initial token is empty', () => {
    const store = useUser()
    expect(store.userInfo.token).toBe('')
  })

  it('setUserInfo updates user info', () => {
    const store = useUser()
    store.setUserInfo({ token: 'abc123' })
    expect(store.userInfo.token).toBe('abc123')
  })

  it('setUserInfo replaces entire userInfo', () => {
    const store = useUser()
    store.setUserInfo({ token: 'abc' })
    store.setUserInfo({ token: 'xyz' })
    expect(store.userInfo.token).toBe('xyz')
  })
})
