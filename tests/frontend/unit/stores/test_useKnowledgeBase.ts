import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, it, expect, vi } from 'vitest'
import { useKnowledgeBase } from '@/store/useKnowledgeBase'

// Mock urlConfig
vi.mock('@/services/urlConfig', () => ({
  default: {
    kbList: vi.fn(),
    createKb: vi.fn(),
  },
}))
import urlResquest from '@/services/urlConfig'

describe('useKnowledgeBase store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('setCurrentId updates currentId', () => {
    const store = useKnowledgeBase()
    store.setCurrentId('KB001')
    expect(store.currentId).toBe('KB001')
  })

  it('setCurrentKbName updates currentKbName', () => {
    const store = useKnowledgeBase()
    store.setCurrentKbName('Test KB')
    expect(store.currentKbName).toBe('Test KB')
  })

  it('setShowDeleteModal toggles', () => {
    const store = useKnowledgeBase()
    store.setShowDeleteModal(true)
    expect(store.showDeleteModal).toBe(true)
    store.setShowDeleteModal(false)
    expect(store.showDeleteModal).toBe(false)
  })

  it('setKnowledgeBaseList updates list', () => {
    const store = useKnowledgeBase()
    const list = [{ kb_id: 'KB1', kb_name: 'Test' }]
    store.setKnowledgeBaseList(list)
    expect(store.knowledgeBaseList).toEqual(list)
  })

  it('getList success updates knowledgeBaseList', async () => {
    const mockData = [
      { kb_id: 'KB1', kb_name: 'First' },
      { kb_id: 'KB2', kb_name: 'Second' },
    ]
    ;(urlResquest.kbList as any).mockResolvedValue({ code: 200, data: mockData })

    const store = useKnowledgeBase()
    await store.getList()
    expect(store.knowledgeBaseList).toEqual(mockData)
  })

  it('getList empty data sets showDefault to default', async () => {
    ;(urlResquest.kbList as any).mockResolvedValue({ code: 200, data: [] })
    const store = useKnowledgeBase()
    await store.getList()
    // pageStatus.default === 1
    expect(store.showDefault).toBe(1)
  })

  it('setSelectList updates selection', () => {
    const store = useKnowledgeBase()
    store.setSelectList(['KB1', 'KB2'])
    expect(store.selectList).toEqual(['KB1', 'KB2'])
  })
})
