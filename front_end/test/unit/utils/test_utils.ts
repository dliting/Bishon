import { describe, it, expect } from 'vitest'
import {
  getStatus, formatFileSize, formatDate,
  resultControl, getRandomString, isMac,
} from '@/utils/utils'
import type { IFileListItem } from '@/utils/types'

describe('getStatus', () => {
  it('loading -> 上传中', () => {
    expect(getStatus({ status: 'loading' } as IFileListItem)).toBe('上传中')
  })
  it('red without errorText -> 解析失败', () => {
    expect(getStatus({ status: 'red' } as IFileListItem)).toBe('解析失败')
  })
  it('red with errorText uses errorText', () => {
    expect(getStatus({ status: 'red', errorText: 'Custom error' } as IFileListItem)).toBe('Custom error')
  })
  it('gray -> 上传成功待解析', () => {
    expect(getStatus({ status: 'gray' } as IFileListItem)).toBe('上传成功待解析')
  })
  it('green -> 解析成功', () => {
    expect(getStatus({ status: 'green' } as IFileListItem)).toBe('解析成功')
  })
  it('yellow -> 解析失败', () => {
    expect(getStatus({ status: 'yellow' } as IFileListItem)).toBe('解析失败')
  })
  it('unknown status -> empty string', () => {
    expect(getStatus({ status: 'unknown' } as IFileListItem)).toBe('')
  })
})

describe('formatFileSize', () => {
  it('negative -> 未知', () => expect(formatFileSize(-1)).toBe('未知'))
  it('500B', () => expect(formatFileSize(500)).toBe('500B'))
  it('1.46KB', () => expect(formatFileSize(1500)).toBe('1.46KB'))
  it('1.43MB', () => expect(formatFileSize(1500000)).toBe('1.43MB'))
  it('1.40G', () => expect(formatFileSize(1500000000)).toBe('1.40G'))
  it('0B', () => expect(formatFileSize(0)).toBe('0B'))
})

describe('formatDate', () => {
  it('parses timestamp', () => {
    expect(formatDate('202401091530')).toBe('2024-01-09')
  })
  it('custom separator', () => {
    expect(formatDate('202401091530', '/')).toBe('2024/01/09')
  })
  it('empty returns empty', () => {
    expect(formatDate('')).toBe('')
  })
})

describe('resultControl', () => {
  it('code 200 resolves with data', async () => {
    await expect(resultControl({ code: 200, data: 'test' })).resolves.toBe('test')
  })
  it('errorCode 0 resolves with result', async () => {
    await expect(resultControl({ errorCode: '0', result: 'ok' })).resolves.toBe('ok')
  })
  it('code 200 resolves with result when no data', async () => {
    await expect(resultControl({ code: 200, result: 'hello' })).resolves.toBe('hello')
  })
  it('other code rejects', async () => {
    await expect(resultControl({ code: 500, msg: 'error' })).rejects.toBeDefined()
  })
})

describe('getRandomString', () => {
  it('default length 5', () => {
    expect(getRandomString()).toHaveLength(5)
  })
  it('custom length', () => {
    expect(getRandomString(10)).toHaveLength(10)
  })
  it('only valid chars', () => {
    const s = getRandomString(20)
    expect(s).toMatch(/^[a-z0-9]+$/)
  })
  it('different calls produce different strings', () => {
    const a = getRandomString(10)
    const b = getRandomString(10)
    // Not guaranteed but extremely unlikely to match
    expect(a).not.toBe(b)
  })
})
