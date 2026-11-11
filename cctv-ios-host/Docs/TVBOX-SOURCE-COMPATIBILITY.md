# TVBox source compatibility

The native catalog importer reads `sites` and `lives` without starting every
provider. It follows up to five HTTP redirects, blocks HTTPS-to-HTTP downgrades,
and accepts catalog files up to 8 MiB. Catalogs may contain up to 2,000 sites
and 500 live lists.

Native type 0/1/4 API responses are bounded at 8 MiB; other local media-service
responses retain the 2 MiB limit.

| TVBox entry | CCTVHost behavior |
| --- | --- |
| `type: 0` HTTP API | Native MacCMS JSON/XML adapter |
| `type: 1` or `type: 4` HTTP API | Native TVBox JSON adapter |
| `.js`, `.mjs`, `.cjs`, `.js.md5`, `.py`, `.py.md5` | Selected script is downloaded and passed to the existing importer |
| `type: 3` JAR / `csp_*.jar` | Unsupported on iOS; requires an Android/JAR runtime |
| `lives` URL | Added as an individual live subscription when selected |

Basic-auth URL user information is converted to an `Authorization` header and
removed from the saved URL. Credential headers stay on the original host, with
same-origin redirects and standard-port HTTP-to-HTTPS upgrades allowed. API and
script-download redirects are limited to five hops, block HTTPS-to-HTTP
downgrades, and strip `Authorization`, `Cookie`, and `Proxy-Authorization` on
other-origin redirects, along with headers named for tokens, API keys,
signatures, sessions, secrets, or credentials. Other TVBox headers already
declared in the catalog are preserved for API requests and script downloads,
including when a resource is updated.

Python scripts use the conventional `Spider` methods supported by the embedded
CPython host. The packaged runtime includes `requests`, BeautifulSoup, and a
pure-Python `Crypto`/`Cryptodome` compatibility package for common PyCryptodome imports:
AES ECB/CBC/CFB/OFB/CTR/GCM/EAX; MD5, SHA-1/2/3 and SHAKE hashes; HMAC and AES-CMAC;
PBKDF2, HKDF and scrypt; AES padding/counter/byte-XOR/number helpers; secure random
bytes; and RSA public/private-key import with PKCS#1 v1.5 encryption and decryption,
plus OAEP public-key encryption. Its AES and
hash implementations use the bundled Python AES core and the interpreter's
`hashlib`/OS random source, so source code can use these APIs without installing
desktop wheels or native extensions.

This is a documented compatibility set, not the complete PyCryptodome package:
RSA signing and OAEP private-key decryption, ECC, DES/3DES, ChaCha20, CCM, and
PyCryptodome-only native/internal modules are not implemented. Provider wheels
and arbitrary C extensions are not installed or loaded by the iPhone runtime.

The supplied `2-hgtv.py` now has offline regression coverage using a synthetic
CENC MP4: the host verifies sample-table parsing, encrypted-sample AES-CTR
decryption, moov box repair, HTTP HEAD/Range responses, and cleanup of its
loopback proxy when the source stops. Its source passed the `stsd` full-box
header to the sample-entry walker; the host applies a narrow compatibility fix
for that pattern. This validates the local playback pipeline without contacting
the provider. Live endpoint availability and AVPlayer behavior on a real stream
still require an on-device check.

The catalog redirect, relative-API, MacCMS type 0, Basic-auth sanitization,
source update, large-catalog, crypto-compatibility, and local encrypted-stream
behaviors have regression coverage. The Foundation/QuartzCore native tests and
an iOS IPA build require macOS and did not run in this Linux workspace.

TVBox/CatVod JavaScript sources that import Node core modules are assigned to
Node.js Mobile, even if an older saved manifest says `runtime: javascript`.
The importer scans `.js`, `.mjs`, and `.cjs` files throughout the extracted ZIP,
including nested helpers and `node_modules`. This gives `node:crypto`,
`node:fs`, `node:http`, and `node:https` their actual Node APIs instead of the
JavaScriptCore convenience shims. The package must still include its JavaScript
dependencies; dynamically computed module names must declare `runtime: node`.
The host rejects child-process execution and Worker creation, and iOS does not
support arbitrary native `.node` addons.
