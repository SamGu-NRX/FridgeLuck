from __future__ import annotations

import asyncio
import hashlib
from typing import Any

import httpx
import orjson
from tenacity import retry, retry_if_exception, stop_after_attempt, wait_exponential_jitter

from .cache_store import CacheStore
from .config import USDA_FOOD_URL, USDA_FOODS_URL, USDA_SEARCH_URL, USDA_USER_AGENT
from .utils import chunked


class USDAAsyncClient:
    def __init__(
        self,
        api_key: str,
        cache: CacheStore,
        *,
        max_connections: int = 32,
        max_keepalive_connections: int = 16,
        concurrency: int = 12,
        connect_timeout: float = 5.0,
        read_timeout: float = 20.0,
        write_timeout: float = 10.0,
        pool_timeout: float = 5.0,
    ):
        self.api_key = api_key
        self.cache = cache
        limits = httpx.Limits(max_connections=max_connections, max_keepalive_connections=max_keepalive_connections)
        timeout = httpx.Timeout(connect=connect_timeout, read=read_timeout, write=write_timeout, pool=pool_timeout)
        self._client = httpx.AsyncClient(
            limits=limits,
            timeout=timeout,
            headers={"Content-Type": "application/json", "User-Agent": USDA_USER_AGENT},
        )
        self._sem = asyncio.Semaphore(max(1, int(concurrency)))

    async def aclose(self) -> None:
        await self._client.aclose()

    def _search_cache_key(self, query: str, data_types: list[str], page_size: int) -> str:
        payload = {"query": query, "dataType": data_types, "pageSize": page_size}
        raw = orjson.dumps(payload, option=orjson.OPT_SORT_KEYS)
        return hashlib.sha256(raw).hexdigest()

    @staticmethod
    def _retryable_exc(exc: BaseException) -> bool:
        if isinstance(exc, httpx.HTTPStatusError):
            status = exc.response.status_code
            return status >= 500 or status == 429
        return isinstance(exc, (httpx.TimeoutException, httpx.TransportError))

    @retry(
        retry=retry_if_exception(_retryable_exc),
        wait=wait_exponential_jitter(initial=0.2, max=3.0),
        stop=stop_after_attempt(4),
        reraise=True,
    )
    async def _post_json(self, url: str, payload: dict[str, Any]) -> dict[str, Any] | list[Any]:
        async with self._sem:
            response = await self._client.post(url, content=orjson.dumps(payload))
            response.raise_for_status()
            return response.json()

    @retry(
        retry=retry_if_exception(_retryable_exc),
        wait=wait_exponential_jitter(initial=0.2, max=3.0),
        stop=stop_after_attempt(4),
        reraise=True,
    )
    async def _get_json(self, url: str) -> dict[str, Any] | list[Any]:
        async with self._sem:
            response = await self._client.get(url)
            response.raise_for_status()
            return response.json()

    async def search(self, query: str, *, data_types: list[str], page_size: int = 40) -> list[dict[str, Any]]:
        cache_key = self._search_cache_key(query=query, data_types=data_types, page_size=page_size)
        cached = self.cache.get_search(cache_key)
        if cached is not None:
            foods = cached.get("foods", [])
            return foods if isinstance(foods, list) else []

        payload = {"query": query, "dataType": data_types, "pageSize": page_size, "pageNumber": 1}
        data = await self._post_json(f"{USDA_SEARCH_URL}?api_key={self.api_key}", payload)
        if not isinstance(data, dict):
            return []
        self.cache.put_search(cache_key, data)
        foods = data.get("foods", [])
        return foods if isinstance(foods, list) else []

    async def get_food(self, fdc_id: int) -> dict[str, Any] | None:
        cached = self.cache.get_food(int(fdc_id))
        if cached is not None:
            return cached
        try:
            data = await self._get_json(f"{USDA_FOOD_URL}/{int(fdc_id)}?api_key={self.api_key}&format=full")
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404:
                return None
            raise
        if not isinstance(data, dict):
            return None
        self.cache.put_food(int(fdc_id), data)
        return data

    async def get_foods(self, fdc_ids: list[int]) -> dict[int, dict[str, Any]]:
        out: dict[int, dict[str, Any]] = {}
        missing: list[int] = []
        for fdc_id in fdc_ids:
            cached = self.cache.get_food(int(fdc_id))
            if cached is not None:
                out[int(fdc_id)] = cached
            else:
                missing.append(int(fdc_id))

        if missing:
            for id_chunk in chunked(sorted(set(missing)), 20):
                payload = {"fdcIds": id_chunk, "format": "full"}
                data = await self._post_json(f"{USDA_FOODS_URL}?api_key={self.api_key}", payload)
                if isinstance(data, list):
                    for row in data:
                        if not isinstance(row, dict):
                            continue
                        row_id = int(row.get("fdcId", 0) or 0)
                        if row_id <= 0:
                            continue
                        out[row_id] = row
                        self.cache.put_food(row_id, row)

            still_missing = [fdc_id for fdc_id in missing if fdc_id not in out]
            if still_missing:
                tasks = [self.get_food(fdc_id) for fdc_id in still_missing]
                results = await asyncio.gather(*tasks, return_exceptions=True)
                for fdc_id, result in zip(still_missing, results):
                    if isinstance(result, dict):
                        out[fdc_id] = result
        return out
