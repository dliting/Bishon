// Knowledge base modal state (create / edit).
import { IUrlListItem, IFileListItem } from '@/utils/types';
import urlResquest from '@/services/urlConfig';
import message from 'ant-design-vue/es/message';
import { getStatus } from '@/utils/utils';
import { getLanguage } from '@/language/index';

const home = getLanguage().home;
const common = getLanguage().common;
export const useKnowledgeModal = defineStore('knowledgeModal', () => {
  // Whether the modal is visible.
  const modalVisible = ref(false);
  const setModalVisible = (flag: boolean) => {
    modalVisible.value = flag;
  };

  // Whether the upload-URL modal is visible.
  const urlModalVisible = ref(false);
  const setUrlModalVisible = (flag: boolean) => {
    urlModalVisible.value = flag;
  };

  // Modal title.
  const modalTitle = ref(home.upload);
  const setModalTitle = (title: string) => {
    modalTitle.value = title;
  };

  // Knowledge base name.
  const knowledgeName = ref('');
  const setKnowledgeName = (name: string) => {
    knowledgeName.value = name;
  };

  // Uploaded file list.
  const fileList = ref<Array<IFileListItem>>([]);
  const setFileList = (list: Array<IFileListItem>) => {
    fileList.value = list;
  };

  // URL upload list.
  const urlList = ref<Array<IUrlListItem>>([]);
  const setUrlList = list => {
    urlList.value = list;
  };

  // Fetch the file list.
  const getFileList = async (kb_id: string) => {
    try {
      const res: any = await urlResquest.fileList({ kb_id });
      if (res.code == 200) {
        res.data.details.forEach((item: any) => {
          item.errorText = getStatus(item);
        });

        setFileList(res.data.details);
      }
    } catch (e) {
      console.log(e);
      message.error(e.msg || common.error);
    }
  };

  // Reset state.
  const $reset = () => {
    modalVisible.value = false;
    modalTitle.value = home.upload;
    knowledgeName.value = '';
    fileList.value = [];
    urlList.value = [];
  };
  return {
    modalVisible,
    setModalVisible,
    urlModalVisible,
    setUrlModalVisible,
    knowledgeName,
    setKnowledgeName,
    fileList,
    setFileList,
    urlList,
    setUrlList,
    modalTitle,
    setModalTitle,
    $reset,
    getFileList,
  };
});
