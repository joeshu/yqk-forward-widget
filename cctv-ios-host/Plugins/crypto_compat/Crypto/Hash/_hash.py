import hashlib


class Hash:
    def __init__(self, algorithm, data=b""):
        self._name = algorithm
        self._hash = hashlib.new(algorithm)
        self.update(data)
        self.digest_size = self._hash.digest_size
        self.block_size = self._hash.block_size

    def update(self, data):
        self._hash.update(data)
        return self

    def digest(self, *args):
        if args:
            return self._hash.digest(*args)
        return self._hash.digest()

    def hexdigest(self, *args):
        if args:
            return self._hash.hexdigest(*args)
        return self._hash.hexdigest()

    def copy(self):
        duplicate = object.__new__(Hash)
        duplicate._name = self._name
        duplicate._hash = self._hash.copy()
        duplicate.digest_size = self.digest_size
        duplicate.block_size = self.block_size
        return duplicate

    def new(self, data=b""):
        return Hash(self._name, data)
