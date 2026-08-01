<template>
  <div class="monitor-page">
    <div class="monitor-header">
      <div class="header-left">
        <img src="../assets/login/logo-small.png" alt="logo" class="logo" />
        <h1 class="title">Bishon 系统监控</h1>
      </div>
      <div class="header-right">
        <span class="refresh-info"> {{ refreshCountdown }}s 后刷新 </span>
        <a-button size="small" @click="fetchHealth">立即刷新</a-button>
        <a-button size="small" type="link" @click="goHome">返回首页</a-button>
      </div>
    </div>

    <div class="monitor-body" v-if="healthData">
      <!-- System overview -->
      <div class="overview-section">
        <div class="overview-card">
          <div class="overview-item">
            <span class="label">系统状态</span>
            <span :class="['status-badge', healthData.status]">
              {{ healthData.status === 'ok' ? '正常' : '异常' }}
            </span>
          </div>
          <div class="overview-item">
            <span class="label">版本</span>
            <span class="value">{{ healthData.version }}</span>
          </div>
          <div class="overview-item">
            <span class="label">运行时间</span>
            <span class="value">{{ formatUptime(healthData.uptime_seconds) }}</span>
          </div>
        </div>
      </div>

      <!-- Service status cards -->
      <div class="services-section">
        <h2 class="section-title">服务状态</h2>
        <div class="services-grid">
          <div
            v-for="(svc, name) in healthData.services"
            :key="name"
            :class="['service-card', svc.status]"
          >
            <div class="card-header">
              <span :class="['status-dot', svc.status]"></span>
              <span class="service-name">{{ serviceNameMap[name] || name }}</span>
            </div>
            <div class="card-body">
              <div class="card-row">
                <span class="label">状态</span>
                <span :class="['status-text', svc.status]">
                  {{ statusTextMap[svc.status] || svc.status }}
                </span>
              </div>
              <div class="card-row" v-if="svc.detail">
                <span class="label">详情</span>
                <span class="value detail">{{ svc.detail }}</span>
              </div>
              <div class="card-row" v-if="svc.latency_ms != null && svc.latency_ms > 0">
                <span class="label">延迟</span>
                <span class="value">{{ svc.latency_ms.toFixed(1) }}ms</span>
              </div>
              <div class="card-row" v-if="svc.last_check">
                <span class="label">最近检测</span>
                <span class="value">{{ formatTime(svc.last_check) }}</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Queue stats -->
      <div class="queue-section" v-if="healthData.queue">
        <h2 class="section-title">请求队列</h2>
        <div class="queue-card">
          <div class="queue-items">
            <div class="queue-item">
              <span class="queue-label">等待中</span>
              <span class="queue-value">{{ healthData.queue.pending_tasks }}</span>
            </div>
            <div class="queue-item">
              <span class="queue-label">执行中</span>
              <span class="queue-value">{{ healthData.queue.active_tasks }}</span>
            </div>
            <div class="queue-item">
              <span class="queue-label">最大并发</span>
              <span class="queue-value">{{ healthData.queue.max_workers }}</span>
            </div>
          </div>
          <div class="queue-bar-container">
            <div class="queue-bar">
              <div class="queue-bar-active" :style="{ width: activePercent + '%' }"></div>
              <div
                class="queue-bar-pending"
                :style="{ left: activePercent + '%', width: pendingPercent + '%' }"
              ></div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div class="monitor-body loading" v-else-if="fetchError">
      <a-result status="error" :title="fetchError">
        <template #extra>
          <a-button type="primary" @click="fetchHealth">重试</a-button>
        </template>
      </a-result>
    </div>

    <div class="monitor-body loading" v-else>
      <a-spin size="large" tip="加载中..." />
    </div>
  </div>
</template>

<script lang="ts" setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { useRouter } from 'vue-router';

const router = useRouter();

interface ServiceInfo {
  status: string;
  detail: string;
  last_check: number;
  last_success: number | null;
  latency_ms: number | null;
}

interface HealthData {
  status: string;
  version: string;
  uptime_seconds: number;
  services: Record<string, ServiceInfo>;
  queue: {
    pending_tasks: number;
    active_tasks: number;
    max_workers: number;
  };
}

const REFRESH_INTERVAL_SECONDS = 30;

const healthData = ref<HealthData | null>(null);
const fetchError = ref<string | null>(null);
const refreshCountdown = ref(REFRESH_INTERVAL_SECONDS);
let countdownTimer: ReturnType<typeof setInterval> | null = null;

const serviceNameMap: Record<string, string> = {
  llm: '大模型服务 (LLM)',
  embedding: '向量服务 (Embedding)',
  rerank: '重排序服务 (Rerank)',
  ocr: 'OCR 服务',
  faiss: '向量数据库 (FAISS)',
  sqlite: '数据库 (SQLite)',
};

const statusTextMap: Record<string, string> = {
  healthy: '正常',
  unhealthy: '异常',
  unknown: '未知',
  disabled: '已禁用',
};

const activePercent = computed(() => {
  if (!healthData.value?.queue) return 0;
  const { active_tasks, max_workers } = healthData.value.queue;
  return max_workers > 0 ? Math.min((active_tasks / max_workers) * 100, 100) : 0;
});

const pendingPercent = computed(() => {
  if (!healthData.value?.queue) return 0;
  const { pending_tasks, max_workers } = healthData.value.queue;
  return max_workers > 0 ? Math.min((pending_tasks / max_workers) * 100, 100) : 0;
});

const fetchHealth = async () => {
  refreshCountdown.value = REFRESH_INTERVAL_SECONDS;
  try {
    const resp = await fetch('/api/health');
    if (!resp.ok) {
      fetchError.value = `API 返回错误 (${resp.status})`;
      return;
    }
    healthData.value = await resp.json();
    fetchError.value = null;
  } catch (e) {
    fetchError.value = '无法连接到服务器';
    console.error('Failed to fetch health data:', e);
  }
};

const formatUptime = (seconds: number): string => {
  if (seconds < 60) return `${Math.floor(seconds)}秒`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}分${Math.floor(seconds % 60)}秒`;
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const mins = Math.floor((seconds % 3600) / 60);
  if (days > 0) return `${days}天${hours}时${mins}分`;
  return `${hours}时${mins}分`;
};

const formatTime = (ts: number): string => {
  if (!ts) return '-';
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString();
};

const goHome = () => {
  router.push('/home');
};

onMounted(() => {
  fetchHealth();
  countdownTimer = setInterval(() => {
    refreshCountdown.value--;
    if (refreshCountdown.value <= 0) {
      fetchHealth();
    }
  }, 1000);
});

onUnmounted(() => {
  if (countdownTimer) clearInterval(countdownTimer);
});
</script>

<style lang="scss" scoped>
.monitor-page {
  min-height: 100vh;
  background: #f3f6fd;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

.monitor-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 64px;
  padding: 0 32px;
  background: #26293b;

  .header-left {
    display: flex;
    align-items: center;
    gap: 16px;

    .logo {
      height: 28px;
      cursor: pointer;
    }

    .title {
      color: #fff;
      font-size: 18px;
      font-weight: 500;
      margin: 0;
    }
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 12px;

    .refresh-info {
      color: #999;
      font-size: 13px;
    }
  }
}

.monitor-body {
  max-width: 960px;
  margin: 0 auto;
  padding: 32px 24px;

  &.loading {
    display: flex;
    justify-content: center;
    padding-top: 120px;
  }
}

.overview-section {
  margin-bottom: 32px;
}

.overview-card {
  display: flex;
  gap: 48px;
  padding: 20px 24px;
  background: #fff;
  border-radius: 8px;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
}

.overview-item {
  display: flex;
  align-items: center;
  gap: 8px;

  .label {
    color: #666;
    font-size: 14px;
  }

  .value {
    color: #333;
    font-size: 14px;
    font-weight: 500;
  }
}

.status-badge {
  display: inline-block;
  padding: 2px 12px;
  border-radius: 12px;
  font-size: 13px;
  font-weight: 500;

  &.ok {
    background: #e6fffb;
    color: #13c2c2;
  }

  &.degraded {
    background: #fff2e8;
    color: #fa8c16;
  }
}

.section-title {
  font-size: 16px;
  font-weight: 500;
  color: #333;
  margin: 0 0 16px 0;
}

.services-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 16px;
}

.service-card {
  padding: 16px 20px;
  background: #fff;
  border-radius: 8px;
  border-left: 4px solid #d9d9d9;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
  transition: border-color 0.3s;

  &.healthy {
    border-left-color: #52c41a;
  }
  &.unhealthy {
    border-left-color: #ff4d4f;
  }
  &.unknown {
    border-left-color: #d9d9d9;
  }
  &.disabled {
    border-left-color: #bfbfbf;
  }
}

.card-header {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 12px;
}

.status-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;

  &.healthy {
    background: #52c41a;
  }
  &.unhealthy {
    background: #ff4d4f;
  }
  &.unknown {
    background: #d9d9d9;
  }
  &.disabled {
    background: #bfbfbf;
  }
}

.service-name {
  font-size: 15px;
  font-weight: 500;
  color: #333;
}

.card-body {
  .card-row {
    display: flex;
    align-items: baseline;
    gap: 8px;
    margin-bottom: 4px;

    .label {
      color: #999;
      font-size: 13px;
      min-width: 60px;
    }

    .value {
      color: #333;
      font-size: 13px;

      &.detail {
        word-break: break-all;
      }
    }
  }
}

.status-text {
  font-size: 13px;
  font-weight: 500;

  &.healthy {
    color: #52c41a;
  }
  &.unhealthy {
    color: #ff4d4f;
  }
  &.unknown {
    color: #999;
  }
  &.disabled {
    color: #bfbfbf;
  }
}

.queue-section {
  margin-top: 32px;
}

.queue-card {
  padding: 20px 24px;
  background: #fff;
  border-radius: 8px;
  box-shadow: 0 1px 4px rgba(0, 0, 0, 0.06);
}

.queue-items {
  display: flex;
  gap: 48px;
  margin-bottom: 16px;
}

.queue-item {
  display: flex;
  flex-direction: column;
  align-items: center;

  .queue-label {
    color: #999;
    font-size: 13px;
    margin-bottom: 4px;
  }

  .queue-value {
    color: #333;
    font-size: 24px;
    font-weight: 600;
  }
}

.queue-bar-container {
  padding: 0 4px;
}

.queue-bar {
  position: relative;
  height: 12px;
  background: #f0f0f0;
  border-radius: 6px;
  overflow: hidden;
}

.queue-bar-active {
  position: absolute;
  top: 0;
  left: 0;
  height: 100%;
  background: #4d71ff;
  border-radius: 6px;
  transition: width 0.5s ease;
}

.queue-bar-pending {
  position: absolute;
  top: 0;
  height: 100%;
  background: #faad14;
  border-radius: 0 6px 6px 0;
  transition: width 0.5s ease, left 0.5s ease;
}
</style>
