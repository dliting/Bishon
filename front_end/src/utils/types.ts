export interface IKnowledgeItem {
  kb_id: string;
  kb_name: string;
  createTime?: any;
  edit?: boolean;
}

export interface IDataSourceItem {
  dataSource?: string; // data source
  detailDataSource?: string; // detailed source info
  file_name: string | null; // file name
  content: string | null; // content
  score: number | null; // score
  file_id: string | null;
  showDetailDataSource?: boolean; // whether to show detailed source info
}

export interface IChatItem {
  type: string; // distinguishes user question vs. AI reply
  question?: string; // question
  answer?: string; // question | reply content
  like?: boolean; // thumbs up
  unlike?: boolean; // thumbs down
  copied?: boolean; // set true on copy to indicate success, then reset to false (highlight briefly after copy)

  showTools?: boolean; // whether the current turn has ended (show copy tooling + stop blinking)
  source?: Array<IDataSourceItem>;
}

// URL parsing status (for frontend display).
export type inputStatus = 'default' | 'inputing' | 'parsing' | 'success' | 'defeat' | 'hover';

// URL list item type.
export interface IUrlListItem {
  status: inputStatus;
  text: string;
  percent: number;
  borderRadius?: string;
}

// Uploaded file item.
export interface IFileListItem {
  file?: File;
  file_name: string;
  status: string;
  file_id: string;
  percent?: number;
  errorText?: string;
}
