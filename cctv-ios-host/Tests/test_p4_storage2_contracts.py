from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class P4StorageContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "Sources" / name).read_text()

    def test_media_migrations_have_independent_markers_and_preserve_defaults(self):
        src = self.source("HostLibraryStore.m")
        self.assertIn('cctv.mediaFavoritesStore.migrated.v1', src)
        self.assertIn('cctv.mediaHistoryStore.migrated.v1', src)
        self.assertIn('setBool:YES forKey:HostMediaFavoritesMarker', src)
        self.assertIn('setBool:YES forKey:HostMediaHistoryMarker', src)
        self.assertIn('dictionaryForKey:HostMediaFavoritesKey', src)
        self.assertIn('arrayForKey:HostMediaHistoryKey', src)
        self.assertNotIn('removeObjectForKey:HostMediaFavoritesKey', src)
        self.assertNotIn('removeObjectForKey:HostMediaHistoryKey', src)

    def test_history_limit_and_sqlite_tables(self):
        src = self.source("HostLibraryStore.m")
        self.assertIn('HostMediaWatchHistoryLimit = 100', src)
        self.assertIn('CREATE TABLE IF NOT EXISTS media_favorites', src)
        self.assertIn('CREATE TABLE IF NOT EXISTS media_watch_history', src)
        self.assertIn('if (pos>=HostMediaWatchHistoryLimit) break;', src)

    def test_callers_and_backup_use_store(self):
        browser = self.source("MediaBrowserViewController.m")
        playback = self.source("MediaPlaybackStateStore.m")
        settings = self.source("SettingsViewController.m")
        backup = self.source("HostBackup.m")
        self.assertNotIn('dictionaryForKey:@"cctv.mediaFavorites.v1"', browser)
        self.assertIn('HostLibraryStore.shared.mediaFavorites', browser)
        self.assertIn('HostLibraryStore.shared mediaWatchHistory', playback)
        self.assertIn('HostLibraryStore.shared.mediaFavorites', settings)
        self.assertIn('HostLibraryStore.shared.mediaWatchHistory', backup)
        self.assertIn('replaceMediaFavorites:backup[@"vodFavorites"]', backup)

    def test_disk_cache_bounds_and_lru(self):
        xml = self.source("XMLTVStore.m")
        meta = self.source("MediaMetadataCache.m")
        self.assertIn('XMLTVDiskTotalLimit', xml)
        self.assertIn('XMLTVDiskEntryLimit', xml)
        self.assertIn('XMLTVDiskFileCountLimit', xml)
        self.assertIn('evictDiskCacheLocked', xml)
        self.assertIn('MediaMetadataPersistentByteLimit', meta)
        self.assertIn('MediaMetadataPersistentEntryLimit', meta)
        self.assertIn('keysSortedByValueUsingComparator', meta)

if __name__ == "__main__":
    unittest.main()
