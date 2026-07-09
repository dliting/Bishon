// Document status values (returned by the API).
export enum fileStatus {
  'success', // upload completed
  'parsed', // parsing completed
  'error', // parsing failed
  'filebig', // uploaded file exceeds the size limit
  'loading', // uploading
}

export enum pageStatus {
  'initing', // initializing; the page content is not yet decided
  'default', // no knowledge base; show the default upload page
  'normal', // has knowledge bases; show the KB list and chat view
  'optionlist', // manage-uploads page
}
