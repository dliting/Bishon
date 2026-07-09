import { IKnowledgeItem } from '@/utils/types';
import { pageStatus } from '@/utils/enum';
// import { resultControl } from '@/utils/utils';
import message from 'ant-design-vue/es/message';

import urlResquest from '@/services/urlConfig';
import { getLanguage } from '@/language/index';

const common = getLanguage().common;

export const useKnowledgeBase = defineStore('knowledgeBase', () => {
  // Currently operated knowledge base ID.
  const currentId = ref('');
  const setCurrentId = (id: string) => {
    currentId.value = id;
  };

  // Selected knowledge base IDs.
  const selectList = ref([]);
  const setSelectList = list => {
    selectList.value = list;
  };

  // Currently operated knowledge base name.
  const currentKbName = ref('');
  const setCurrentKbName = (id: string) => {
    currentKbName.value = id;
  };

  // Fetched knowledge base list.
  const knowledgeBaseList = ref<Array<IKnowledgeItem>>([]);
  const setKnowledgeBaseList = list => {
    knowledgeBaseList.value = list;
  };

  // If no knowledge bases exist, show the default page.
  const showDefault = ref(pageStatus.initing);
  const setDefault = str => {
    showDefault.value = str;
  };

  // Whether to show the delete modal.
  const showDeleteModal = ref(false);
  const setShowDeleteModal = (flag: boolean) => {
    showDeleteModal.value = flag;
  };

  // Fetch the knowledge base list.
  const getList = async () => {
    try {
      const res: any = await urlResquest.kbList();
      if (+res.code === 200) {
        setKnowledgeBaseList(res.data);
        if (res?.data?.length > 0) {
          setDefault(pageStatus.normal);

          if (!selectList.value.length) {
            selectList.value = [res.data[0].kb_id];
            setCurrentKbName(res.data[0].kb_name);
          }
        } else {
          setDefault(pageStatus.default);
        }
      }
    } catch (e) {
      message.error(e.msg || common.error);
    }
  };

  return {
    currentId,
    setCurrentId,
    knowledgeBaseList,
    setKnowledgeBaseList,
    showDeleteModal,
    setShowDeleteModal,
    showDefault,
    setDefault,
    getList,
    currentKbName,
    setCurrentKbName,
    selectList,
    setSelectList,
  };
});
