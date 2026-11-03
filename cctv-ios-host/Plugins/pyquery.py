"""A compact PyQuery-compatible wrapper for the selectors used by TVBox PYs."""

import copy

from bs4 import BeautifulSoup, NavigableString, Tag


def _markup(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value or "")


class PyQuery:
    def __init__(self, markup="", selector=None, **kwargs):
        self._soup = None
        if isinstance(markup, PyQuery):
            self._soup = markup._soup
            self._nodes = list(markup._nodes)
        elif isinstance(markup, (BeautifulSoup, Tag, NavigableString)):
            self._nodes = [markup]
            self._soup = markup if isinstance(markup, BeautifulSoup) else markup.find_parent()
        elif isinstance(markup, (list, tuple)):
            self._nodes = list(markup)
            self._soup = next((node if isinstance(node, BeautifulSoup) else node.find_parent()
                               for node in self._nodes if isinstance(node, (BeautifulSoup, Tag))), None)
        else:
            self._soup = BeautifulSoup(_markup(markup), "html.parser")
            self._nodes = [self._soup]
        if selector:
            self._nodes = self._select(str(selector))

    @classmethod
    def _from_nodes(cls, nodes, soup=None):
        result = cls.__new__(cls)
        result._nodes = list(nodes)
        result._soup = soup
        if result._soup is None:
            result._soup = next((node if isinstance(node, BeautifulSoup) else node.find_parent()
                                 for node in result._nodes if isinstance(node, (BeautifulSoup, Tag))), None)
        return result

    def _select(self, selector):
        found = []
        seen = set()
        for node in self._nodes:
            if not hasattr(node, "select"):
                continue
            for match in node.select(selector):
                identity = id(match)
                if identity not in seen:
                    found.append(match)
                    seen.add(identity)
        return found

    def __call__(self, selector=None):
        return self if selector is None else self.find(selector)

    def find(self, selector):
        return self._from_nodes(self._select(selector), self._soup)

    def items(self):
        return (self._from_nodes([node], self._soup) for node in self._nodes)

    def eq(self, index):
        try:
            return self._from_nodes([self._nodes[index]], self._soup)
        except IndexError:
            return self._from_nodes([], self._soup)

    @property
    def length(self):
        return len(self._nodes)

    def attr(self, name, value=None):
        if isinstance(name, dict):
            for key, content in name.items():
                self.attr(key, content)
            return self
        if value is not None:
            for node in self._nodes:
                if isinstance(node, Tag):
                    node.attrs[str(name)] = value
            return self
        if not self._nodes or not isinstance(self._nodes[0], Tag):
            return None
        result = self._nodes[0].get(str(name))
        return " ".join(str(part) for part in result) if isinstance(result, list) else result

    def text(self, value=None):
        if value is not None:
            for node in self._nodes:
                if isinstance(node, Tag):
                    node.clear()
                    node.append(NavigableString(str(value)))
            return self
        return "".join(node.get_text() if isinstance(node, (BeautifulSoup, Tag)) else str(node)
                       for node in self._nodes)

    def html(self, value=None):
        if value is not None:
            fragment = BeautifulSoup(_markup(value), "html.parser")
            for node in self._nodes:
                if isinstance(node, Tag):
                    node.clear()
                    for child in list(fragment.contents):
                        node.append(copy.deepcopy(child))
            return self
        node = self._nodes[0] if self._nodes else None
        return node.decode_contents() if isinstance(node, (BeautifulSoup, Tag)) else None

    def append(self, value):
        if isinstance(value, PyQuery):
            children = value._nodes
        elif isinstance(value, (Tag, NavigableString)):
            children = [value]
        else:
            fragment = BeautifulSoup(_markup(value), "html.parser")
            children = list(fragment.contents)
        for node in self._nodes:
            if isinstance(node, Tag):
                for child in children:
                    node.append(copy.deepcopy(child))
        return self

    def remove(self):
        for node in tuple(self._nodes):
            if isinstance(node, Tag):
                node.decompose()
        self._nodes = []
        return self

    def empty(self):
        for node in self._nodes:
            if isinstance(node, Tag):
                node.clear()
        return self

    def children(self, selector=None):
        nodes = [child for node in self._nodes if isinstance(node, Tag)
                 for child in node.find_all(recursive=False)]
        result = self._from_nodes(nodes, self._soup)
        return result.filter(selector) if selector else result

    def parent(self):
        parents = []
        for node in self._nodes:
            parent = node.parent if isinstance(node, (Tag, NavigableString)) else None
            if isinstance(parent, Tag) and parent not in parents:
                parents.append(parent)
        return self._from_nodes(parents, self._soup)

    def filter(self, selector):
        if not selector:
            return self
        try:
            import soupsieve
            nodes = [node for node in self._nodes if isinstance(node, Tag) and soupsieve.match(selector, node)]
        except Exception:
            nodes = [node for node in self._nodes if isinstance(node, Tag) and node in node.parent.select(selector)]
        return self._from_nodes(nodes, self._soup)

    def val(self, value=None):
        if value is not None:
            return self.attr("value", value)
        return self.attr("value")

    def hasClass(self, name):
        return any(isinstance(node, Tag) and name in node.get("class", []) for node in self._nodes)

    def addClass(self, name):
        for node in self._nodes:
            if isinstance(node, Tag):
                classes = list(node.get("class", []))
                for item in str(name).split():
                    if item not in classes:
                        classes.append(item)
                node["class"] = classes
        return self

    def removeClass(self, name):
        removals = set(str(name).split())
        for node in self._nodes:
            if isinstance(node, Tag):
                node["class"] = [item for item in node.get("class", []) if item not in removals]
        return self

    def __iter__(self):
        return self.items()

    def __len__(self):
        return len(self._nodes)

    def __bool__(self):
        return bool(self._nodes)

    def __getitem__(self, key):
        if isinstance(key, str):
            return self.attr(key)
        if isinstance(key, slice):
            return self._from_nodes(self._nodes[key], self._soup)
        return self.eq(key)

    def __str__(self):
        node = self._nodes[0] if self._nodes else None
        return str(node) if node is not None else ""


def PyQueryFactory(markup="", selector=None, **kwargs):
    return PyQuery(markup, selector, **kwargs)


__all__ = ["PyQuery", "PyQueryFactory"]
