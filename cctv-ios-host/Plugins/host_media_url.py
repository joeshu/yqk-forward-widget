"""HTTP transport encoding without changing already escaped/signed URL bytes."""
import urllib.parse


def http_url(value):
    parts = urllib.parse.urlsplit(str(value or ''))
    if parts.scheme.lower() not in ('http', 'https') or not parts.hostname:
        raise ValueError('invalid HTTP media URL')
    if parts.username or parts.password or any(c in str(value) for c in '\r\n\x00'):
        raise ValueError('invalid HTTP media URL')
    host = parts.hostname.encode('idna').decode('ascii')
    if ':' in host:
        host = '[' + host + ']'
    if parts.port:
        host += ':' + str(parts.port)
    # Preserve %, +, query order and separators: re-encoding an existing escape
    # or parsing/rebuilding a signed query changes its signature.
    path = urllib.parse.quote(parts.path, safe="/%:@!$&'()*+,;=-._~")
    query = urllib.parse.quote(parts.query, safe="%/?@!$&'()*+,;=:-._~[]")
    return urllib.parse.urlunsplit((parts.scheme, host, path, query, ''))
