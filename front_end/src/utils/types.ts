export interface IKnowledgeItem {
  kb_id: string;
  kb_name: string;
  createTime?: any;
  edit?: boolean;
}

export interface IDataSourceItem {
  file_name: string | null;
  content: string | null;
  score: number | null;
  file_id: string | null;
  embed_version?: string;
  retrieval_query?: string;
  kernel?: string;
}

// Grouped source documents for UI display (same file_name aggregated).
export interface IGroupedSource {
  file_name: string;
  file_id: string | null;
  chunks: IDataSourceItem[];
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
  groupedSource?: Array<IGroupedSource>; // pre-computed for UI display
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
