"""Contract tests for the bounded, service-scoped Spider base cache."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

BASE_PATH = Path(__file__).resolve().parents[1] / 'Plugins' / 'base' / 'spider.py'
SPEC = importlib.util.spec_from_file_location('cctvhost_test_spider_base', BASE_PATH)
base = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(base)


class SpiderBaseCacheTests(unittest.TestCase):
    def test_safe_site_url_survives_new_spider_instance_in_same_service_data_dir(self):
        with tempfile.TemporaryDirectory() as data_dir, patch.dict(
                os.environ, {'CCTVHOST_DATA_DIR': data_dir}, clear=False):
            first = base.Spider()
            first.setCache('ptt01_dynamic_site_url', 'https://ptt01.example/path', expire=60)

            second = base.Spider()
            self.assertEqual(second.getCache('ptt01_dynamic_site_url'), 'https://ptt01.example/path')
            persisted = json.loads((Path(data_dir) / 'spider-cache.json').read_text())
            self.assertEqual(persisted['version'], 1)
            self.assertEqual(list(persisted['entries']), ['ptt01_dynamic_site_url'])

    def test_credentials_and_non_site_cache_keys_are_never_persisted(self):
        with tempfile.TemporaryDirectory() as data_dir, patch.dict(
                os.environ, {'CCTVHOST_DATA_DIR': data_dir}, clear=False):
            spider = base.Spider()
            spider.setCache('ptt01_dynamic_site_url', 'https://example.test/?token=private', expire=60)
            spider.setCache('session_token', 'secret-value', expire=60)
            self.assertFalse((Path(data_dir) / 'spider-cache.json').exists())
            self.assertIsNone(base.Spider().getCache('ptt01_dynamic_site_url'))

    def test_persistent_site_url_expires_with_its_declared_ttl(self):
        with tempfile.TemporaryDirectory() as data_dir, patch.dict(
                os.environ, {'CCTVHOST_DATA_DIR': data_dir}, clear=False):
            base.Spider().setCache('provider_site_url', 'https://example.test', expire=0.02)
            time.sleep(0.03)
            self.assertIsNone(base.Spider().getCache('provider_site_url'))

    def test_delete_removes_memory_and_persistent_site_url(self):
        with tempfile.TemporaryDirectory() as data_dir, patch.dict(
                os.environ, {'CCTVHOST_DATA_DIR': data_dir}, clear=False):
            spider = base.Spider()
            spider.setCache('provider_site_url', 'https://example.test', expire=60)
            spider.delCache('provider_site_url')
            self.assertIsNone(base.Spider().getCache('provider_site_url'))
            self.assertFalse((Path(data_dir) / 'spider-cache.json').exists())


if __name__ == '__main__':
    unittest.main()
