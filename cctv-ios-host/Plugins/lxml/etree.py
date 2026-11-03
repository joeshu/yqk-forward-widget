"""Pure-Python lxml.etree compatibility backed by html5lib/ElementPath."""

import xml.etree.ElementTree as _ET

import elementpath as _elementpath
import html5lib as _html5lib


class _Element:
    """Wrap an ElementTree node with the lxml methods used by TVBox spiders."""

    __slots__ = ("_node",)

    def __init__(self, node):
        self._node = node

    def xpath(self, expression, namespaces=None, **kwargs):
        if not isinstance(expression, str):
            raise TypeError("XPath expression must be a string")
        values = _elementpath.select(
            self._node,
            expression,
            namespaces=namespaces or {},
        )
        if not isinstance(values, list):
            values = [values]
        return [_wrap(value) for value in values]

    def get(self, key, default=None):
        return self._node.get(key, default)

    def itertext(self):
        return self._node.itertext()

    def text_content(self):
        return "".join(self._node.itertext())

    def __iter__(self):
        return (_wrap(child) for child in self._node)

    def __len__(self):
        return len(self._node)

    def __getitem__(self, index):
        return _wrap(self._node[index])

    def __getattr__(self, name):
        return getattr(self._node, name)


def _wrap(value):
    if isinstance(value, _ET.Element):
        return _Element(value)
    return value


class HTMLParser:
    def __init__(self, encoding=None, recover=True, **kwargs):
        self.encoding = encoding
        self.recover = recover
        self.options = kwargs


class XMLParser:
    def __init__(self, **kwargs):
        self.options = kwargs


def _html_root(source, parser=None):
    if source is None:
        return None
    options = {"treebuilder": "etree", "namespaceHTMLElements": False}
    encoding = getattr(parser, "encoding", None)
    if encoding:
        options["transport_encoding"] = encoding
    tree = _html5lib.parse(source, **options)
    root = tree.getroot() if callable(getattr(tree, "getroot", None)) else tree
    return _wrap(root)


def HTML(source, parser=None, base_url=None):
    try:
        return _html_root(source, parser)
    except Exception:
        return None


def fromstring(source, parser=None, base_url=None):
    if isinstance(parser, HTMLParser):
        root = _html_root(source, parser)
        if root is None:
            raise ValueError("HTML source is empty")
        return root
    node = _ET.fromstring(source)
    return _wrap(node)


def tostring(element, encoding="us-ascii", method="xml", **kwargs):
    node = element._node if isinstance(element, _Element) else element
    return _ET.tostring(node, encoding=encoding, **kwargs)


def XML(source, parser=None, base_url=None):
    return fromstring(source, parser=parser, base_url=base_url)


Element = _ET.Element
SubElement = _ET.SubElement
ParseError = _ET.ParseError
_ElementTree = _ET.ElementTree
