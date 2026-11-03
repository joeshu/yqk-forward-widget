"""HTML helpers matching the lxml.html entry points used by PyTVBox."""

from . import etree

HTMLParser = etree.HTMLParser


def fromstring(source, **kwargs):
    return etree.HTML(source, **kwargs)


def document_fromstring(source, **kwargs):
    return etree.HTML(source, **kwargs)


def tostring(element, encoding="unicode", **kwargs):
    return etree.tostring(element, encoding=encoding, **kwargs)
