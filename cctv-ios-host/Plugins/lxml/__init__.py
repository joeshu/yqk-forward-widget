"""Small lxml-compatible surface for Python TVBox spiders on iOS.

This package intentionally implements the HTML/XPath subset used by the
bundled community Spider collection. It is not a drop-in replacement for the
native lxml C extension.
"""

from . import etree, html

__all__ = ["etree", "html"]
__version__ = "cctvhost-compat-1"
