"""Single source of truth shared with generated Foundation constants."""
import json
from pathlib import Path
REGISTRY=json.loads(Path(__file__).with_name('media-capabilities.json').read_text())
NETWORK_TRANSPORTS=frozenset(REGISTRY['networkTransports'])
CICADA_FORMATS=frozenset(REGISTRY['cicadaFormats'])
UNSUPPORTED_CONTAINERS=frozenset(REGISTRY['unsupportedContainers'])
UNSUPPORTED_VIDEO_CODECS=frozenset(REGISTRY['unsupportedVideoCodecs'])

AV_FORMATS=frozenset(REGISTRY['avFormats'])
