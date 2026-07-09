import re

from langchain_text_splitters import CharacterTextSplitter

from bishon_kernel.configs.model_config import SENTENCE_SIZE


class ChineseTextSplitter(CharacterTextSplitter):
    def __init__(self, pdf: bool = False, sentence_size: int = SENTENCE_SIZE, **kwargs):
        super().__init__(**kwargs)
        self.pdf = pdf
        self.sentence_size = sentence_size

    def split_text(self, text: str) -> list[str]:   # TODO: logic here needs further refinement.
        if self.pdf:
            text = re.sub(r"\n{3,}", r"\n", text)
            text = re.sub(r'\s', " ", text)
            text = re.sub(r"\n\n", "", text)

        text = re.sub(r'([;；.!?。！？\?])([^”’])', r"\1\n\2", text)  # single-char sentence terminators
        text = re.sub(r'(\.{6})([^"’”」』])', r"\1\n\2", text)  # ASCII ellipsis
        text = re.sub(r'(\…{2})([^"’”」』])', r"\1\n\2", text)  # CJK ellipsis
        text = re.sub(r'([;；!?。！？\?]["’”」』]{0,2})([^;；!?，。！？\?])', r'\1\n\2', text)
        # When a terminator sits before a closing quote, the quote is the real sentence boundary;
        # move the newline after the quote. The earlier substitutions carefully preserved quotes.
        text = text.rstrip()  # Strip trailing newlines from the paragraph end.
        # Many rule sets also split on semicolons; we intentionally ignore them here, and likewise
        # dashes and English double quotes. Adjust with simple tweaks if needed.
        ls = [i for i in text.split("\n") if i]
        for ele in ls:
            if len(ele) > self.sentence_size:
                ele1 = re.sub(r'([,，.]["’”」』]{0,2})([^,，.])', r'\1\n\2', ele)
                ele1_ls = ele1.split("\n")
                for ele_ele1 in ele1_ls:
                    if len(ele_ele1) > self.sentence_size:
                        ele_ele2 = re.sub(r'([\n]{1,}| {2,}["’”」』]{0,2})([^\s])', r'\1\n\2', ele_ele1)
                        ele2_ls = ele_ele2.split("\n")
                        for ele_ele2 in ele2_ls:
                            if len(ele_ele2) > self.sentence_size:
                                ele_ele3 = re.sub('( ["’”」』]{0,2})([^ ])', r'\1\n\2', ele_ele2)
                                ele2_id = ele2_ls.index(ele_ele2)
                                ele2_ls = ele2_ls[:ele2_id] + [i for i in ele_ele3.split("\n") if i] + ele2_ls[
                                                                                                       ele2_id + 1:]
                        ele_id = ele1_ls.index(ele_ele1)
                        ele1_ls = ele1_ls[:ele_id] + [i for i in ele2_ls if i] + ele1_ls[ele_id + 1:]

                idx = ls.index(ele)
                ls = ls[:idx] + [i for i in ele1_ls if i] + ls[idx + 1:]
        return ls
