"""Multi-source XMLTV priority, background recovery, and failure-layer regressions."""
import datetime
import importlib.util
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_epg_recovery', ROOT / 'ysp-live-v9.5.16.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)
ZONE = datetime.timezone(datetime.timedelta(hours=8))
TODAY = datetime.datetime.now(ZONE).replace(hour=12, minute=0, second=0, microsecond=0)


def row(channel='cctv1', day=0, title='primary', hour=12, duration=3600):
    start = int((TODAY + datetime.timedelta(days=day)).replace(hour=hour).timestamp())
    return dict(channel=channel, start=start, stop=start + duration, title=title, description='')


def feed(*rows):
    root = ET.Element('tv')
    for slug in sorted({r['channel'] for r in rows}):
        ch = ET.SubElement(root, 'channel', id=slug)
        ET.SubElement(ch, 'display-name').text = slug
    for r in rows:
        stamp = lambda value: datetime.datetime.fromtimestamp(value, ZONE).strftime('%Y%m%d%H%M%S %z')
        p = ET.SubElement(root, 'programme', channel=r['channel'], start=stamp(r['start']), stop=stamp(r['stop']))
        ET.SubElement(p, 'title').text = r['title']
    return ET.tostring(root, encoding='utf-8')


class EPGRecoveryTests(unittest.TestCase):
    def cache(self, **kwargs):
        cache = live.EPGCache(**kwargs)
        self.addCleanup(cache.close)
        return cache

    def finish(self, cache):
        with cache.changed:
            self.assertTrue(cache.changed.wait_for(lambda: not cache.loading, timeout=3))

    def test_secondary_fills_missing_channels_and_days_without_replacing_primary(self):
        data = {'first': feed(row()), 'second': feed(row(title='wrong'), row('cctv2'), row(day=1))}
        cache = self.cache(urls=data, fetcher=data.__getitem__)
        cache.request_refresh()
        self.finish(cache)
        self.assertEqual([(p['channel'], p['title']) for p in cache.programmes],
                         [('cctv1', 'primary'), ('cctv1', 'primary'), ('cctv2', 'primary')])
        self.assertEqual([p['added'] for p in cache.stats()['providers']], [1, 2])
        self.assertFalse(cache.stats()['error'])

    def test_secondary_cross_midnight_overlap_is_rejected(self):
        primary = row(hour=23, duration=7200)
        overlapping = row(day=1, hour=0, duration=7200)
        after = row(day=1, hour=2)
        cache = self.cache()
        rows, added = cache.merge_programmes([primary], [overlapping, after])
        self.assertEqual(len(rows), 2)
        self.assertEqual(added, [after])

    def test_combined_result_is_bounded_and_retains_primary(self):
        cache = self.cache()
        cache.max_items = 1
        rows, added = cache.merge_programmes([row()], [row('cctv2')])
        self.assertEqual(rows, (row(),))
        self.assertFalse(added)

    def test_partial_failure_preserves_missing_cached_channel_and_retries_despite_fresh_data(self):
        calls = []
        def fetch(url):
            calls.append(url)
            if url == 'second':
                raise OSError('offline')
            return feed(row(title='fresh'))
        cache = self.cache(urls=['first', 'second'], fetcher=fetch)
        cache.programmes = (row(title='old'), row('cctv2', title='cached'))
        cache.updated = time.time() - 7200
        cache.request_refresh()
        self.finish(cache)
        self.assertEqual([p['title'] for p in cache.programmes], ['fresh', 'cached'])
        self.assertEqual(cache.stats()['cached_fallback_channels'], ['cctv2'])
        self.assertTrue(cache.stats()['warning'])
        self.assertGreater(cache.retry_at, time.time())
        cache.retry_at = time.time() - 1
        cache.request_refresh()
        self.finish(cache)
        self.assertEqual(len(calls), 4)

    def test_all_sources_fail_without_erasing_previous_programmes(self):
        cache = self.cache(urls=['first'], fetcher=lambda _: (_ for _ in ()).throw(OSError('offline')))
        previous = (row(),)
        cache.programmes, cache.updated = previous, time.time() - 7200
        cache.request_refresh()
        self.finish(cache)
        self.assertEqual(cache.programmes, previous)
        self.assertTrue(cache.error)
        self.assertTrue(cache.stats()['stale'])

    def test_first_usable_source_is_published_before_supplement_download_finishes(self):
        entered, release = threading.Event(), threading.Event()
        def fetch(url):
            if url == 'second':
                entered.set()
                release.wait(2)
            return feed(row())
        cache = self.cache(urls=['first', 'second'], fetcher=fetch)
        self.addCleanup(release.set)
        cache.request_refresh()
        self.assertTrue(entered.wait(1))
        cache.wait_for_initial()
        self.assertEqual(len(cache.programmes), 1)
        self.assertTrue(cache.loading)
        release.set()
        self.finish(cache)

    def test_scheduler_refreshes_without_client_requests_and_start_is_idempotent(self):
        twice = threading.Event()
        calls = []
        def fetch(url):
            calls.append(url)
            if len(calls) >= 2:
                twice.set()
            return feed(row())
        cache = self.cache(urls=['first'], ttl=.08, fetcher=fetch)
        cache.start()
        scheduler = cache.scheduler
        cache.start()
        self.assertIs(cache.scheduler, scheduler)
        self.assertTrue(twice.wait(2))
        cache.close()
        self.assertFalse(scheduler.is_alive())

    def test_scheduler_recovers_after_failure_without_any_client_request(self):
        failed, recovered = threading.Event(), threading.Event()
        calls = []
        def fetch(url):
            calls.append(url)
            if len(calls) == 1:
                failed.set()
                raise OSError('offline')
            recovered.set()
            return feed(row())
        cache = self.cache(urls=['first'], fetcher=fetch)
        cache.start()
        self.assertTrue(failed.wait(1))
        self.finish(cache)
        with cache.changed:
            cache.retry_at = time.time() + .05
            cache.changed.notify_all()
        self.assertTrue(recovered.wait(2))
        self.finish(cache)
        self.assertEqual(len(cache.programmes), 1)
        self.assertFalse(cache.error)

    def test_close_unblocks_waiters_and_discards_late_results(self):
        entered, release, returned = threading.Event(), threading.Event(), threading.Event()
        def fetch(url):
            entered.set()
            release.wait(2)
            return feed(row())
        cache = self.cache(urls=['first'], fetcher=fetch)
        self.addCleanup(release.set)
        cache.start()
        self.assertTrue(entered.wait(1))
        waiter = threading.Thread(target=lambda: (cache.wait_for_initial(), returned.set()), daemon=True)
        waiter.start()
        cache.close()
        self.assertTrue(returned.wait(1))
        release.set()
        waiter.join(1)
        self.assertFalse(cache.programmes)

    def test_source_reports_distinguish_download_parse_matching_and_date_failures(self):
        data = {'download': OSError('https://example.test/?token=secret'), 'parse': b'not XML',
                'match': b'<tv><channel id="unknown"/></tv>', 'date': feed(row(day=-20))}
        def fetch(url):
            if isinstance(data[url], Exception):
                raise data[url]
            return data[url]
        cache = self.cache(urls=data, fetcher=fetch)
        cache.request_refresh()
        self.finish(cache)
        self.assertEqual([p['stage'] for p in cache.stats()['providers']],
                         ['epg_download', 'epg_parse', 'epg_match', 'epg_data'])
        self.assertNotIn('secret', str(cache.stats()['providers']))

    def test_failure_layers_preserve_exception_type_and_history_is_bounded(self):
        channel = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        selector = live.SourceSelector()
        selector.channel = 'test'
        @live.playback_stage('playlist')
        def fail():
            raise live.ProxyError(502, 'playlist failed')
        with self.assertRaises(live.ProxyError) as error:
            fail()
        self.assertEqual(error.exception.playback_stage, 'playlist')
        with mock.patch.object(live, 'CHANNEL_MAP', {'test': channel}):
            selector.failure('device', 'failed', stage='playlist')
            for index in range(20):
                live.record_channel_issue('test', 'segment', 'failed ' + str(index), 'device')
        self.assertEqual(len(channel.issues), 8)
        self.assertEqual(selector.snapshot()['sources']['device']['error_stage'], 'playlist')


if __name__ == '__main__':
    unittest.main()
