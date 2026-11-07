import re
from html.parser import HTMLParser as _StdlibHTMLParser
from xml.etree import ElementTree as _ET

try:
    import elementpath as _elementpath
except Exception:
    _elementpath = None

try:
    import html5lib as _html5lib
except Exception:
    _html5lib = None


_VOID_HTML_TAGS = frozenset({
    'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
    'link', 'meta', 'param', 'source', 'track', 'wbr',
})


def _strip_ns(tag):
    if isinstance(tag, str) and tag.startswith('{') and '}' in tag:
        return tag.split('}', 1)[1]
    return tag


def _clean_Tree(elem):
    elem.tag = _strip_ns(elem.tag)
    elem.attrib = {_strip_ns(k): v for k, v in elem.attrib.items()}
    for child in list(elem):
        if not isinstance(child.tag, str):
            elem.remove(child)
            continue
        _clean_Tree(child)
    return elem


class _EtreeHTMLBuilder(_StdlibHTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = _ET.Element('html')
        self.stack = [self.root]
        self.last_closed = None

    def handle_starttag(self, tag, attrs):
        tag = _strip_ns(tag.lower())
        attr_dict = {
            _strip_ns(k): (v if v is not None else '')
            for k, v in attrs if k
        }
        if tag == 'html' and len(self.stack) == 1 and not len(self.root) and not self.root.attrib:
            self.root.attrib.update(attr_dict)
            self.last_closed = None
            return
        elem = _ET.Element(tag, attr_dict)
        parent = self.stack[-1]
        parent.append(elem)
        if tag in _VOID_HTML_TAGS:
            self.last_closed = elem
        else:
            self.stack.append(elem)
            self.last_closed = None

    def handle_startendtag(self, tag, attrs):
        tag = _strip_ns(tag.lower())
        attr_dict = {
            _strip_ns(k): (v if v is not None else '')
            for k, v in attrs if k
        }
        elem = _ET.Element(tag, attr_dict)
        self.stack[-1].append(elem)
        self.last_closed = elem

    def handle_endtag(self, tag):
        tag = _strip_ns(tag.lower())
        if tag in _VOID_HTML_TAGS:
            return
        for idx in range(len(self.stack) - 1, 0, -1):
            if self.stack[idx].tag == tag:
                self.last_closed = self.stack[idx]
                del self.stack[idx:]
                break

    def handle_data(self, data):
        if not data:
            return
        if self.last_closed is not None:
            self.last_closed.tail = (self.last_closed.tail or '') + data
        else:
            curr = self.stack[-1]
            curr.text = (curr.text or '') + data


def _parse_html(text):
    if isinstance(text, bytes):
        text = text.decode('utf-8', 'ignore')
    raw = text or '<html/>'
    if _html5lib is not None:
        doc = _html5lib.parse(raw, namespaceHTMLElements=False)
        return _clean_Tree(doc)
    builder = _EtreeHTMLBuilder()
    builder.feed(raw)
    builder.close()
    return _clean_Tree(builder.root)


def _split_top_level(expr, sep):
    parts = []
    buf = []
    depth_sq = 0
    depth_par = 0
    quote_char = None
    for ch in expr:
        if quote_char:
            buf.append(ch)
            if ch == quote_char:
                quote_char = None
            continue
        if ch in ('"', "'"):
            quote_char = ch
            buf.append(ch)
        elif ch == '[':
            depth_sq += 1
            buf.append(ch)
        elif ch == ']':
            depth_sq = max(0, depth_sq - 1)
            buf.append(ch)
        elif ch == '(':
            depth_par += 1
            buf.append(ch)
        elif ch == ')':
            depth_par = max(0, depth_par - 1)
            buf.append(ch)
        elif ch == sep and depth_sq == 0 and depth_par == 0:
            parts.append(''.join(buf).strip())
            buf = []
        else:
            buf.append(ch)
    if buf:
        parts.append(''.join(buf).strip())
    return [p for p in parts if p]


def _tokenize_xpath_steps(path):
    steps = []
    i = 0
    n = len(path)
    while i < n:
        if path.startswith('//', i):
            axis = '//'
            i += 2
        elif path[i] == '/':
            axis = '/'
            i += 1
        else:
            axis = '/'
        buf = []
        depth_sq = 0
        depth_par = 0
        quote_char = None
        while i < n:
            ch = path[i]
            if quote_char:
                buf.append(ch)
                if ch == quote_char:
                    quote_char = None
                i += 1
                continue
            if ch in ('"', "'"):
                quote_char = ch
                buf.append(ch)
                i += 1
            elif ch == '[':
                depth_sq += 1
                buf.append(ch)
                i += 1
            elif ch == ']':
                depth_sq = max(0, depth_sq - 1)
                buf.append(ch)
                i += 1
            elif ch == '(':
                depth_par += 1
                buf.append(ch)
                i += 1
            elif ch == ')':
                depth_par = max(0, depth_par - 1)
                buf.append(ch)
                i += 1
            elif ch == '/' and depth_sq == 0 and depth_par == 0:
                break
            else:
                buf.append(ch)
                i += 1
        token = ''.join(buf).strip()
        if token == '.' and axis == '/':
            continue
        steps.append((axis, token))
    return steps


def _parse_step_predicates(token):
    if '[' not in token:
        return token.strip(), []
    name_end = token.index('[')
    tag = token[:name_end].strip() or '*'
    rest = token[name_end:]
    preds = []
    buf = []
    depth = 0
    quote_char = None
    for ch in rest:
        if quote_char:
            buf.append(ch)
            if ch == quote_char:
                quote_char = None
            continue
        if ch in ('"', "'"):
            quote_char = ch
            buf.append(ch)
        elif ch == '[':
            if depth > 0:
                buf.append(ch)
            depth += 1
        elif ch == ']':
            depth -= 1
            if depth == 0:
                preds.append(''.join(buf).strip())
                buf = []
            else:
                buf.append(ch)
        else:
            if depth > 0:
                buf.append(ch)
    return tag, preds


def _node_string_value(elem):
    return ''.join(elem.itertext())


def _eval_single_predicate(elem, idx, total, pred, parent_map):
    pred = pred.strip()
    if not pred:
        return True
    if ' and ' in pred:
        parts = _split_top_level(pred.replace(' and ', ' & '), '&')
        if len(parts) > 1:
            return all(_eval_single_predicate(elem, idx, total, p, parent_map) for p in parts)
    if ' or ' in pred:
        parts = _split_top_level(pred.replace(' or ', ' | '), '|')
        if len(parts) > 1:
            return any(_eval_single_predicate(elem, idx, total, p, parent_map) for p in parts)
    if pred.isdigit():
        return idx == int(pred)
    if pred == 'last()':
        return idx == total
    m_last = re.match(r'^last\(\)\s*-\s*(\d+)$', pred)
    if m_last:
        return idx == max(1, total - int(m_last.group(1)))
    m_pos = re.match(r'^position\(\)\s*(<=|>=|<|>|=|!=)\s*(\d+)$', pred)
    if m_pos:
        op, val = m_pos.group(1), int(m_pos.group(2))
        if op == '=':
            return idx == val
        if op == '!=':
            return idx != val
        if op == '<':
            return idx < val
        if op == '<=':
            return idx <= val
        if op == '>':
            return idx > val
        if op == '>=':
            return idx >= val
    if pred.startswith('not(') and pred.endswith(')'):
        return not _eval_single_predicate(elem, idx, total, pred[4:-1], parent_map)
    m_contains = re.match(
        r'^contains\(\s*(@[\w:-]+|text\(\)|\.)\s*,\s*(["\'])(.*?)\2\s*\)$',
        pred,
    )
    if m_contains:
        target, _, needle = m_contains.groups()
        hay = elem.attrib.get(target[1:], '') if target.startswith('@') else _node_string_value(elem)
        return needle in hay
    m_starts = re.match(
        r'^starts-with\(\s*(@[\w:-]+|text\(\)|\.)\s*,\s*(["\'])(.*?)\2\s*\)$',
        pred,
    )
    if m_starts:
        target, _, needle = m_starts.groups()
        hay = elem.attrib.get(target[1:], '') if target.startswith('@') else _node_string_value(elem)
        return hay.startswith(needle)
    m_attr_eq = re.match(r'^@([\w:-]+)\s*(=|!=)\s*(["\'])(.*?)\3$', pred)
    if m_attr_eq:
        attr_name, op, _, expected = m_attr_eq.groups()
        actual = elem.attrib.get(attr_name)
        return (actual == expected) if op == '=' else (actual != expected)
    m_text_eq = re.match(r'^(?:text\(\)|\.)\s*(=|!=)\s*(["\'])(.*?)\2$', pred)
    if m_text_eq:
        op, _, expected = m_text_eq.groups()
        actual = _node_string_value(elem).strip()
        return (actual == expected) if op == '=' else (actual != expected)
    if pred.startswith('@'):
        return pred[1:].strip() in elem.attrib
    sub_results = _fallback_xpath_single(elem, pred, parent_map)
    return bool(sub_results)


def _fallback_xpath_single(root_elem, expr, parent_map):
    expr = expr.strip()
    if not expr:
        return []
    if expr.startswith('.//'):
        expr = '//' + expr[3:]
    elif expr.startswith('./'):
        expr = expr[2:]
    elif expr == '.':
        return [root_elem]
    steps = _tokenize_xpath_steps(expr)
    current = [root_elem]
    for step_index, (axis, raw_token) in enumerate(steps):
        if not raw_token:
            continue
        tag, preds = _parse_step_predicates(raw_token)
        next_items = []
        for node in current:
            if not isinstance(node, _ET.Element):
                continue
            if tag == '..':
                parent = parent_map.get(node)
                if parent is not None and parent not in next_items:
                    next_items.append(parent)
                continue
            if tag == '.':
                if node not in next_items:
                    next_items.append(node)
                continue
            if tag.startswith('@'):
                attr_name = tag[1:]
                if attr_name == '*':
                    next_items.extend(list(node.attrib.values()))
                elif attr_name in node.attrib:
                    next_items.append(node.attrib[attr_name])
                continue
            if tag == 'text()':
                if axis == '//':
                    for text_part in node.itertext():
                        if text_part:
                            next_items.append(text_part)
                else:
                    if node.text:
                        next_items.append(node.text)
                    for child in list(node):
                        if child.tail:
                            next_items.append(child.tail)
                continue
            if axis == '//':
                candidates = [
                    desc for desc in node.iter()
                    if (desc is not node or step_index > 0 or expr.startswith('//'))
                    and (tag in ('*', 'node()') or desc.tag == tag)
                ]
                if step_index == 0 and node in candidates and node.tag == 'html' and tag != 'html':
                    candidates = [c for c in candidates if c is not node]
            else:
                if step_index == 0 and not expr.startswith('/') and node.tag == tag:
                    candidates = [node] + [
                        child for child in list(node)
                        if tag in ('*', 'node()') or child.tag == tag
                    ]
                else:
                    candidates = [
                        child for child in list(node)
                        if tag in ('*', 'node()') or child.tag == tag
                    ]
            for pred in preds:
                total = len(candidates)
                candidates = [
                    cand for idx, cand in enumerate(candidates, 1)
                    if _eval_single_predicate(cand, idx, total, pred, parent_map)
                ]
            for cand in candidates:
                if cand not in next_items:
                    next_items.append(cand)
        current = next_items
    return current


def _fallback_xpath(root_elem, expr):
    parent_map = {child: parent for parent in root_elem.iter() for child in list(parent)}
    branches = _split_top_level(expr, '|')
    results = []
    for branch in branches:
        for item in _fallback_xpath_single(root_elem, branch, parent_map):
            if isinstance(item, _ET.Element):
                if item not in results:
                    results.append(item)
            else:
                results.append(item)
    return results


class ElementWrapper:
    def __init__(self, elem):
        self._elem = elem

    def xpath(self, expr, **kwargs):
        if _elementpath is not None:
            res = _elementpath.select(self._elem, expr, **kwargs)
        else:
            res = _fallback_xpath(self._elem, expr)
        out = []
        for item in res:
            if isinstance(item, _ET.Element):
                out.append(ElementWrapper(item))
            else:
                out.append(item)
        return out

    @property
    def attrib(self):
        return self._elem.attrib

    def get(self, key, default=None):
        return self._elem.get(key, default)

    @property
    def text(self):
        return self._elem.text

    @property
    def tail(self):
        return self._elem.tail

    @property
    def tag(self):
        return self._elem.tag

    def __iter__(self):
        for child in self._elem:
            yield ElementWrapper(child)

    def __len__(self):
        return len(self._elem)

    def __getitem__(self, idx):
        return ElementWrapper(self._elem[idx])

    def find(self, path, namespaces=None):
        res = self._elem.find(path, namespaces)
        return ElementWrapper(res) if res is not None else None

    def findall(self, path, namespaces=None):
        return [ElementWrapper(el) for el in self._elem.findall(path, namespaces)]

    def iter(self, tag=None):
        for el in self._elem.iter(tag):
            yield ElementWrapper(el)

    def itertext(self):
        return self._elem.itertext()

    def text_content(self):
        return ''.join(self._elem.itertext())


def HTML(text, parser=None):
    return ElementWrapper(_parse_html(text))


def fromstring(text, parser=None):
    return HTML(text, parser=parser)


def tostring(element, encoding=None, method='html', **kwargs):
    raw = element._elem if isinstance(element, ElementWrapper) else element
    enc = encoding or 'bytes'
    if enc is str or enc == 'unicode':
        return _ET.tostring(raw, encoding='unicode', method=method if method in ('xml', 'html', 'text') else 'html')
    return _ET.tostring(raw, encoding=enc if isinstance(enc, str) and enc != 'bytes' else 'utf-8')


def Element(tag, attrib=None, **extra):
    return ElementWrapper(_ET.Element(tag, attrib or {}, **extra))


def SubElement(parent, tag, attrib=None, **extra):
    raw_parent = parent._elem if isinstance(parent, ElementWrapper) else parent
    return ElementWrapper(_ET.SubElement(raw_parent, tag, attrib or {}, **extra))


class ParserError(Exception):
    pass


class XMLSyntaxError(ParserError):
    pass


class _TargetRelayParser(_StdlibHTMLParser):
    def __init__(self, target=None, **kwargs):
        super().__init__(convert_charrefs=True)
        self.target = target

    def feed(self, data):
        if isinstance(data, bytes):
            data = data.decode('utf-8', 'ignore')
        super().feed(data or '')

    def handle_starttag(self, tag, attrs):
        if self.target is not None and hasattr(self.target, 'start'):
            self.target.start(tag, {k: (v if v is not None else '') for k, v in attrs if k})

    def handle_endtag(self, tag):
        if self.target is not None and hasattr(self.target, 'end'):
            self.target.end(tag)

    def handle_data(self, data):
        if self.target is not None and hasattr(self.target, 'data'):
            self.target.data(data)

    def handle_comment(self, data):
        if self.target is not None and hasattr(self.target, 'comment'):
            self.target.comment(data)


class HTMLParser(_TargetRelayParser):
    pass


class XMLParser(_TargetRelayParser):
    pass


__all__ = [
    'HTML', 'fromstring', 'tostring', 'Element', 'SubElement',
    'HTMLParser', 'XMLParser', 'ParserError', 'XMLSyntaxError', 'ElementWrapper',
]
