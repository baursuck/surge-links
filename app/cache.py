import time
from collections import OrderedDict


class TTLCache[V]:
    """Tiny in-process LRU+TTL cache for hot redirect lookups.

    During a campaign spike the same few codes get most of the traffic, so a
    short TTL removes almost all database reads without running a separate Redis.
    """

    def __init__(self, ttl_seconds: float, max_items: int) -> None:
        self._ttl = ttl_seconds
        self._max = max_items
        self._data: OrderedDict[str, tuple[float, V]] = OrderedDict()

    def get(self, key: str) -> V | None:
        item = self._data.get(key)
        if item is None:
            return None
        expires, value = item
        if expires < time.monotonic():
            self._data.pop(key, None)
            return None
        self._data.move_to_end(key)
        return value

    def set(self, key: str, value: V, ttl: float | None = None) -> None:
        self._data[key] = (time.monotonic() + (self._ttl if ttl is None else ttl), value)
        self._data.move_to_end(key)
        while len(self._data) > self._max:
            self._data.popitem(last=False)

    def invalidate(self, key: str) -> None:
        self._data.pop(key, None)

    def __len__(self) -> int:
        return len(self._data)
