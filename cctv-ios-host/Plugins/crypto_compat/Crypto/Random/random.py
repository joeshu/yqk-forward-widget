"""System-random compatible helpers."""

import secrets

choice = secrets.choice
randbelow = secrets.randbelow
randbits = secrets.randbits
randrange = secrets.SystemRandom().randrange
getrandbits = secrets.randbits
