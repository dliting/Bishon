<template>
  <div class="">
    <slot name="default"></slot>
  </div>
</template>
<script lang="ts" setup></script>
<style lang="scss" scoped>
.my-list {
  width: 800px;
  height: 460px;
  background: #fbfbfe;
  box-sizing: border-box;
  border: 1px dashed #cecece;
  border-radius: 12px;
}
</style>
