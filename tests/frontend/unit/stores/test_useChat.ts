import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, it, expect } from 'vitest'
import { useChat } from '@/store/useChat'

describe('useChat store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('initial state: QA_List is empty', () => {
    const store = useChat()
    expect(store.QA_List).toEqual([])
  })

  it('initial state: showModal is false', () => {
    const store = useChat()
    expect(store.showModal).toBe(false)
  })

  it('clearQAList empties the list', () => {
    const store = useChat()
    store.QA_List = [{ type: 'user', question: 'test' }] as any
    store.clearQAList()
    expect(store.QA_List).toEqual([])
  })

  it('showModal can be toggled', () => {
    const store = useChat()
    store.showModal = true
    expect(store.showModal).toBe(true)
    store.showModal = false
    expect(store.showModal).toBe(false)
  })
})
