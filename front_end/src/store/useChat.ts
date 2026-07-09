import { IChatItem } from '@/utils/types';

export const useChat = defineStore(
  'useChat',
  () => {
    // Conversation list.
    const QA_List = ref<Array<IChatItem>>([]);
    const clearQAList = () => {
      QA_List.value = [];
    };

    const showModal = ref(false);

    return {
      QA_List,
      clearQAList,
      showModal,
    };
  },
  {
    persist: {
      storage: localStorage,
    },
  }
);
