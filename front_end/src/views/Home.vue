<template>
  <div class="page">
    <DefaultPage v-if="showDefault === pageStatus.default" @change="change" />
    <Chat v-else-if="showDefault === pageStatus.normal" />
    <OptionList v-else-if="showDefault === pageStatus.optionlist" />
  </div>
</template>
<script lang="ts" setup>
import { pageStatus } from '@/utils/enum';
import DefaultPage from '@/components/Defaultpage.vue';
import { useKnowledgeBase } from '@/store/useKnowledgeBase';
import Chat from '@/components/Chat.vue';
import OptionList from '@/components/OptionList.vue';

const { showDefault } = storeToRefs(useKnowledgeBase());

const { setDefault, getList } = useKnowledgeBase();

// Actions after starting a conversation:
// 1. Switch to the chat view.
// 2. Show the default knowledge bases.
const change = str => {
  setDefault(str);
  getList();
};

onMounted(() => {
  getList();
});
</script>
<style lang="scss" scoped>
.page {
  width: 100%;
  height: 100%;
  background: #f3f6fd;
}
</style>
