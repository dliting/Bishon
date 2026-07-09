import { setActivePinia, createPinia } from 'pinia'
import { beforeEach, describe, it, expect, vi } from 'vitest'
import { useKnowledgeModal } from '@/store/useKnowledgeModal'

// Mock urlConfig
vi.mock('@/services/urlConfig', () => ({
  default: {
    fileList: vi.fn(),
  },
}))
import urlResquest from '@/services/urlConfig'

describe('useKnowledgeModal store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('initial modalVisible is false', () => {
    const store = useKnowledgeModal()
    expect(store.modalVisible).toBe(false)
  })

  it('initial urlModalVisible is false', () => {
    const store = useKnowledgeModal()
    expect(store.urlModalVisible).toBe(false)
  })

  it('setModalVisible toggles', () => {
    const store = useKnowledgeModal()
    store.setModalVisible(true)
    expect(store.modalVisible).toBe(true)
  })

  it('setUrlModalVisible toggles', () => {
    const store = useKnowledgeModal()
    store.setUrlModalVisible(true)
    expect(store.urlModalVisible).toBe(true)
  })

  it('setKnowledgeName updates name', () => {
    const store = useKnowledgeModal()
    store.setKnowledgeName('My KB')
    expect(store.knowledgeName).toBe('My KB')
  })

  it('setFileList updates list', () => {
    const store = useKnowledgeModal()
    const list = [{ file_name: 'test.txt', status: 'green' }]
    store.setFileList(list as any)
    expect(store.fileList).toEqual(list)
  })

  it('$reset clears all state', () => {
    const store = useKnowledgeModal()
    store.setModalVisible(true)
    store.setKnowledgeName('Test')
    store.setFileList([{ file_name: 'a.txt' }] as any)
    store.$reset()
    expect(store.modalVisible).toBe(false)
    expect(store.knowledgeName).toBe('')
    expect(store.fileList).toEqual([])
    expect(store.urlList).toEqual([])
  })

  it('getFileList updates fileList on success', async () => {
    const mockDetails = [
      { file_id: 'f1', file_name: 'a.txt', status: 'green', bytes: 100, timestamp: '20240101', msg: '' },
    ]
    ;(urlResquest.fileList as any).mockResolvedValue({ code: 200, data: { details: mockDetails } })
    const store = useKnowledgeModal()
    await store.getFileList('KB001')
    expect(store.fileList.length).toBe(1)
    expect(store.fileList[0].file_name).toBe('a.txt')
  })
})
