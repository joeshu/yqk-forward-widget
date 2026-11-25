"""Single source of truth shared with generated Foundation constants."""
import json
from pathlib import Path
REGISTRY=json.loads(Path(__file__).with_name('media-capabilities.json').read_text())
NETWORK_TRANSPORTS=frozenset(REGISTRY['networkTransports'])
CICADA_FORMATS=frozenset(REGISTRY['cicadaFormats'])
UNSUPPORTED_CONTAINERS=frozenset(REGISTRY['unsupportedContainers'])
UNSUPPORTED_VIDEO_CODECS=frozenset(REGISTRY['unsupportedVideoCodecs'])

AV_FORMATS=frozenset(REGISTRY['avFormats'])

# Protocol maturity table: verified / engine_dependent / experimental.
PROTOCOL_CAPABILITY_STATUSES=('verified','engine_dependent','experimental')
PROTOCOL_CAPABILITIES=dict(REGISTRY.get('protocolCapabilities',{}))

def protocol_capability(name):
    """Return the maturity status for a protocol identifier, or 'unknown'."""
    if not isinstance(name,str):return 'unknown'
    return PROTOCOL_CAPABILITIES.get(name.strip().lower(),'unknown')
