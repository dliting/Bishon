enum EUrlType {
  POST = 'post',
  GET = 'get',
}
interface IUrlValueConfig {
  type: EUrlType;
  url: string;
  showLoading?: boolean;
  loadingId?: string;
  // errorToast?: boolean; // enabled by default
  cancelRepeat?: boolean;
  sign?: boolean; // whether to enable request signing
  param?: any;
  [key: string]: any;
}
interface IUrlConfig {
  [key: string]: IUrlValueConfig;
}
import services from '.';

export const userId = 'default_user';

// AJAX endpoint config.
const urlConfig: IUrlConfig = {
  checkLogin: {
    type: EUrlType.GET,
    url: '/checkLogin.s',
  },
  getLoginInfo: {
    type: EUrlType.POST,
    url: '/j_spring_security_check',
  },
  // List knowledge bases.
  kbList: {
    type: EUrlType.POST,
    url: '/local_doc_qa/list_knowledge_base',
    showLoading: true,
    param: {
      user_id: userId,
    },
  },
  // Create a knowledge base.
  createKb: {
    type: EUrlType.POST,
    url: '/local_doc_qa/new_knowledge_base',
    showLoading: true,
    param: {
      user_id: userId,
    },
  },
  // Upload files.
  uploadFile: {
    type: EUrlType.POST,
    url: '/local_doc_qa/upload_files',
    param: {
      user_id: userId,
    },
  },
  // Delete a knowledge base.
  deleteKB: {
    type: EUrlType.POST,
    url: '/local_doc_qa/delete_knowledge_base',
    param: {
      user_id: userId,
    },
  },
  // Delete files.
  deleteFile: {
    type: EUrlType.POST,
    url: '/local_doc_qa/delete_files',
    showLoading: true,
    param: {
      user_id: userId,
      kb_id: '',
      file_ids: [],
    },
  },
  // Upload a web page (URL).
  uploadUrl: {
    type: EUrlType.POST,
    url: '/local_doc_qa/upload_weblink',
    param: {
      user_id: userId,
    },
  },
  kbConfig: {
    type: EUrlType.POST,
    url: '/local_doc_qa/rename_knowledge_base',
    showLoading: true,
    param: {
      user_id: userId,
      kb_id: '',
      new_kb_name: '',
    },
  },
  // Get the upload status of files in a knowledge base.
  fileList: {
    type: EUrlType.POST,
    url: '/local_doc_qa/list_files',
    param: {
      user_id: userId,
      kb_id: '',
    },
  },
};
const urlResquest: any = {};
Object.keys(urlConfig).forEach(key => {
  urlResquest[key] = (params: any, option: any = {}) => {
    const { type, url, param, ...other } = urlConfig[key];
    return services[type](url, { ...param, ...params }, { ...other, ...option });
  };
});
export default urlResquest;
