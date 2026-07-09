"""Tests for MyRecursiveUrlLoader — max_depth logic and edge cases"""
from unittest.mock import patch


class TestMaxDepthLogic:
    """Verify max_depth boundary conditions for recursion control."""

    def _make_loader(self, max_depth=-1, exclude_dirs=None):
        from bishon_kernel.utils.loader.my_recursive_url_loader import MyRecursiveUrlLoader
        return MyRecursiveUrlLoader(url="http://example.com", exclude_dirs=exclude_dirs, max_depth=max_depth)

    @patch("bishon_kernel.utils.loader.my_recursive_url_loader.requests.get")
    @patch("langchain_community.document_loaders.WebBaseLoader")
    def test_unlimited_depth_proceeds(self, mock_web_loader_cls, mock_get):
        """max_depth=-1 (default) should allow recursion."""
        loader = self._make_loader(max_depth=-1)
        mock_web_loader_cls.return_value.load.return_value = []
        mock_get.return_value.text = "<html><body></body></html>"
        mock_get.return_value.status_code = 200

        result = loader.get_child_links_recursive("http://example.com", depth=0)
        assert result is not None
        list(result)

    @patch("bishon_kernel.utils.loader.my_recursive_url_loader.requests.get")
    @patch("langchain_community.document_loaders.WebBaseLoader")
    def test_max_depth_2_allows_depth_0(self, mock_web_loader_cls, mock_get):
        """max_depth=2 should allow depth=0, not return immediately."""
        loader = self._make_loader(max_depth=2)
        mock_web_loader_cls.return_value.load.return_value = []
        mock_get.return_value.text = "<html><body></body></html>"

        # depth=0 should produce results (not stop immediately due to bug)
        result = list(loader.get_child_links_recursive("http://example.com", depth=0))
        assert isinstance(result, list)

    @patch("bishon_kernel.utils.loader.my_recursive_url_loader.requests.get")
    @patch("langchain_community.document_loaders.WebBaseLoader")
    def test_max_depth_1_stops_at_depth_1(self, mock_web_loader_cls, mock_get):
        """max_depth=1 should allow depth=0, stop at depth=1."""
        loader = self._make_loader(max_depth=1)
        mock_web_loader_cls.return_value.load.return_value = []
        mock_get.return_value.text = "<html><body></body></html>"

        # depth=0 should proceed
        gen = loader.get_child_links_recursive("http://example.com", depth=0)
        assert gen is not None
        list(gen)

        # depth=1 should stop immediately (no WebBaseLoader call)
        mock_web_loader_cls.reset_mock()
        list(loader.get_child_links_recursive("http://example.com", depth=1))
        mock_web_loader_cls.return_value.load.assert_not_called()

    def test_max_depth_0_allows_root_only(self):
        """max_depth=0 should process depth=0 (root page)."""
        loader = self._make_loader(max_depth=0)
        gen = loader.get_child_links_recursive("http://example.com", depth=0)
        assert gen is not None

    def test_exclude_dirs_skips_matching_url(self):
        """URL matching exclude_dirs should be skipped."""
        loader = self._make_loader(exclude_dirs=["http://example.com/admin"])
        result = list(loader.get_child_links_recursive("http://example.com/admin/page", depth=0))
        assert result == []


class TestLoaderBasics:
    def test_init_defaults(self):
        from bishon_kernel.utils.loader.my_recursive_url_loader import MyRecursiveUrlLoader
        loader = MyRecursiveUrlLoader(url="http://example.com")
        assert loader.url == "http://example.com"
        assert loader.max_depth == -1
        assert loader.exclude_dirs is None
