import urlResquest from '@/services/urlConfig';
import { formatFileSize, resultControl, formatDate } from '@/utils/utils';
import { message } from 'ant-design-vue';
import { useKnowledgeBase } from '@/store/useKnowledgeBase';
const { currentId } = storeToRefs(useKnowledgeBase());

export const useOptiionList = defineStore('optionList', () => {
  const dataSource = ref([]);
  const setDataSource = (array: []) => {
    dataSource.value = array;
  };
  const timer = ref();

  const getDetails = async () => {
    try {
      const res: any = await resultControl(await urlResquest.fileList({ kb_id: currentId.value }));

      setDataSource([]);
      res?.details.forEach((item: any, index) => {
        dataSource.value.push({
          id: 10000 + index,
          file_id: item?.file_id,
          file_name: item?.file_name,
          status: item?.status,
          bytes: formatFileSize(item?.bytes || 0),
          createtime: formatDate(item?.timestamp),
          errortext: item?.status === 'gray' || item?.status === 'green' ? '' : item?.msg,
        });
      });

      const flag = res?.details.some(item => {
        return item.status === 'gray';
      });
      console.log(flag);
      if (flag) {
        console.log('有解析中的  10后再次请求');
        // Some files are still parsing.
        timer.value = setTimeout(() => {
          clearTimeout(timer.value);
          getDetails();
        }, 10000);
      } else {
        console.log('全部解析完成');
      }
    } catch (error) {
      console.log(error);
      message.error(error.msg || '获取知识库详情失败');
    }
  };

  return {
    dataSource,
    setDataSource,
    getDetails,
    timer,
  };
});
