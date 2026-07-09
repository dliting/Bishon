<template>
  <a-layout>
    <Head />
    <a-layout>
      <a-layout-sider width="280" style="background: #fff">
        <Sider />
      </a-layout-sider>
      <a-layout>
        <a-layout-content class="main">
          <router-view></router-view>
        </a-layout-content>
      </a-layout>
    </a-layout>
  </a-layout>
</template>
<script lang="ts" setup>
import Head from '@/components/Head.vue';
import Sider from '@/components/Sider.vue';
</script>
<style lang="scss" scoped></style>
