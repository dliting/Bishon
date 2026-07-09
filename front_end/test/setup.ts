import { vi } from 'vitest'
import { defineStore, createPinia, acceptHMRUpdate, getActivePinia, mapActions, mapGetters, mapState, mapStores, mapWritableState, setActivePinia, storeToRefs } from 'pinia'
import {
  ref, reactive, computed, watch, watchEffect, onMounted, onUnmounted,
  onBeforeMount, onBeforeUnmount, nextTick, toRef, toRefs, isRef, unref,
  provide, inject, onActivated, onDeactivated, shallowRef, triggerRef,
  customRef, toRaw, markRaw, effectScope, EffectScope, getCurrentInstance,
  getCurrentScope, onScopeDispose, readonly, isReactive, isReadonly, isProxy,
  shallowReactive, shallowReadonly, toValue, defineComponent, h,
  createApp,
} from 'vue'
import { onBeforeRouteLeave, onBeforeRouteUpdate } from 'vue-router'

// Make auto-imported globals available in tests
Object.assign(globalThis, {
  defineStore, ref, reactive, computed, watch, watchEffect,
  onMounted, onUnmounted, onBeforeMount, onBeforeUnmount,
  nextTick, toRef, toRefs, isRef, unref, provide, inject,
  onActivated, onDeactivated, shallowRef, triggerRef,
  customRef, toRaw, markRaw, effectScope, EffectScope,
  getCurrentInstance, getCurrentScope, onScopeDispose,
  readonly, isReactive, isReadonly, isProxy,
  shallowReactive, shallowReadonly, toValue, defineComponent, h,
  createApp, createPinia, setActivePinia, storeToRefs,
  acceptHMRUpdate, getActivePinia,
  mapActions, mapGetters, mapState, mapStores, mapWritableState,
  onBeforeRouteLeave, onBeforeRouteUpdate,
})

// Mock localStorage for pinia persist
const localStorageMock = (() => {
  let store: Record<string, string> = {}
  return {
    getItem: (key: string) => store[key] ?? null,
    setItem: (key: string, value: string) => { store[key] = String(value) },
    removeItem: (key: string) => { delete store[key] },
    clear: () => { store = {} },
    get length() { return Object.keys(store).length },
    key: (index: number) => Object.keys(store)[index] ?? null,
  }
})()
Object.defineProperty(globalThis, 'localStorage', { value: localStorageMock })

// Mock navigator for isMac
Object.defineProperty(globalThis, 'navigator', {
  value: { userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' },
  writable: true,
  configurable: true,
})

// Mock ant-design-vue
vi.mock('ant-design-vue/es/message', () => ({
  default: { error: vi.fn(), success: vi.fn(), warning: vi.fn() },
}))
vi.mock('ant-design-vue', () => ({
  message: { error: vi.fn(), success: vi.fn(), warning: vi.fn() },
}))

// Mock language module to avoid circular deps
vi.mock('@/language/index', () => ({
  getLanguage: () => ({
    home: { upload: '上传文档' },
    common: { error: '操作失败' },
  }),
}))
