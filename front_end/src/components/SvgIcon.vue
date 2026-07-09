<template>
  <svg aria-hidden="true">
    <use :href="symbolId" fill="currentColor" />
  </svg>
</template>

<script>
import { defineComponent, computed } from 'vue';

export default defineComponent({
  name: 'SvgIcon',
  props: {
    prefix: {
      type: String,
      default: 'icon',
    },
    name: {
      type: String,
      required: true,
    },
  },
  setup(props) {
    const symbolId = computed(() => `#${props.prefix}-${props.name}`);
    return { symbolId };
  },
});
</script>
<style>
/* svg {
  width: 28px;
  height: 28px;
} */
</style>
