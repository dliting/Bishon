import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, it, expect, vi } from 'vitest'
import { useKnowledgeBase } from '@/store/useKnowledgeBase'

// Mock urlConfig
vi.mock('@/services/urlConfig', () => ({
  default: {
    fileList: vi.fn(),
  },
}))

describe('useOptiionList store', () => {
  let store: any
  let urlResquest: any

  beforeEach(async () => {
    const pinia = createPinia()
    setActivePinia(pinia)
    const kbStore = useKnowledgeBase()
    kbStore.setCurrentId('KB001')
    // Dynamic import after pinia setup so top-level storeToRefs works
    const mod = await import('@/store/useOptiionList')
    store = mod.useOptiionList()
    urlResquest = (await import('@/services/urlConfig')).default
    vi.clearAllMocks()
  })

  it('initial dataSource is empty', () => {
    expect(store.dataSource).toEqual([])
  })

  it('getDetails populates dataSource', async () => {
    const mockDetails = [
      { file_id: 'f1', file_name: 'doc.txt', status: 'green', bytes: 1024, timestamp: '202401091530', msg: '' },
    ]
    urlResquest.fileList.mockResolvedValue({
      code: 200,
      data: { details: mockDetails },
    })
    await store.getDetails()
    expect(store.dataSource.length).toBe(1)
    expect(store.dataSource[0].bytes).toBe('1.00KB')
    expect(store.dataSource[0].createtime).toBe('2024-01-09')
  })

  it('getDetails with gray status sets timer', async () => {
    const mockDetails = [
      { file_id: 'f1', file_name: 'doc.txt', status: 'gray', bytes: 0, timestamp: '20240109', msg: '' },
    ]
    urlResquest.fileList.mockResolvedValue({
      code: 200,
      data: { details: mockDetails },
    })
    vi.useFakeTimers()
    await store.getDetails()
    expect(store.timer).toBeDefined()
    vi.useRealTimers()
  })
})
