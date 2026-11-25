"""Phase 3 — incremental list refresh contracts.

Covers two layers:

1. A pure-Python mirror of the Objective-C ``HostListDiffHelper`` algorithm
   (LIS-of-old-positions diff). The mirror is a source-code contract: the ObjC
   implementation must produce structurally identical results for the same
   inputs. We exercise sorting, filtering, appends/removes, pure reorders,
   content-only updates, empty sets and mixed move+update transitions.

2. Source-level contracts on the MediaBrowserViewController media favorites
   list: single-entry unfavorite must go through the diff helper + UIKit batch
   updates (deleteRows/insertRows/moveRows/reloadRows) instead of a full
   ``reloadData``, poster URLs are prefetched via ``HostImageLoader`` on appear,
   and the helper is imported and used. ``HostListDiffHelper.{h,m}`` must be
   pure Foundation (no UIKit import).
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


def diff(old_items, new_items, identity, equal=None):
    """Mirror of HostListDiffHelper+diffFromOld:toNew:identityBlock:isEqualBlock:."""
    old = list(old_items or [])
    new = list(new_items or [])

    def identity_for(item):
        ident = identity(item) if identity else None
        if isinstance(ident, str) and ident:
            return ident
        return "__host_ptr:%s" % id(item)

    old_positions = {}
    for i, item in enumerate(old):
        old_positions.setdefault(identity_for(item), []).append(i)

    not_found = -1
    common_old_for_new = []
    inserted = []
    matched_old = set()
    for j, item in enumerate(new):
        bucket = old_positions.get(identity_for(item))
        if bucket:
            old_index = bucket.pop(0)
            common_old_for_new.append(old_index)
            matched_old.add(old_index)
        else:
            common_old_for_new.append(not_found)
            inserted.append(j)

    deleted = [i for i in range(len(old)) if i not in matched_old]

    common_old_seq = []
    common_new_idx = []
    for j, oi in enumerate(common_old_for_new):
        if oi >= 0:
            common_old_seq.append(oi)
            common_new_idx.append(j)

    n = len(common_old_seq)
    dp_len = [1] * n
    prev = [-1] * n
    best_end = 0
    for i in range(n):
        cur = common_old_seq[i]
        for k in range(i):
            if common_old_seq[k] < cur and dp_len[k] + 1 > dp_len[i]:
                dp_len[i] = dp_len[k] + 1
                prev[i] = k
        if dp_len[i] > dp_len[best_end]:
            best_end = i

    kept_for_lis = set()
    cur = best_end if n else None
    while cur is not None and cur < n:
        kept_for_lis.add(common_old_seq[cur])
        p = prev[cur]
        cur = None if p < 0 else p

    moves = []
    reloaded = []
    for i in range(n):
        old_index = common_old_seq[i]
        new_index = common_new_idx[i]
        if old_index not in kept_for_lis:
            moves.append({"from": old_index, "to": new_index})
        if equal is not None and not equal(old[old_index], new[new_index]):
            reloaded.append(new_index)

    return {
        "inserted": inserted,
        "deleted": deleted,
        "moves": moves,
        "reloaded": reloaded,
    }


class DiffAlgorithmContracts(unittest.TestCase):
    """The diff helper must report the minimal UIKit-friendly operations."""

    def _ids(self, items):
        return lambda it: it["id"]

    def _equal(self, a, b):
        return a.get("payload") == b.get("payload")

    def test_empty_to_empty_is_noop(self):
        d = diff([], [], self._ids(None))
        self.assertEqual(d, {"inserted": [], "deleted": [], "moves": [], "reloaded": []})

    def test_empty_to_filled_is_all_inserts(self):
        items = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        d = diff([], items, self._ids(items))
        self.assertEqual(d["inserted"], [0, 1, 2])
        self.assertEqual(d["deleted"], [])
        self.assertEqual(d["moves"], [])
        self.assertEqual(d["reloaded"], [])

    def test_filled_to_empty_is_all_deletes(self):
        items = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        d = diff(items, [], self._ids(items))
        self.assertEqual(d["deleted"], [0, 1, 2])
        self.assertEqual(d["inserted"], [])
        self.assertEqual(d["moves"], [])
        self.assertEqual(d["reloaded"], [])

    def test_filter_subset_is_only_deletes(self):
        old = [{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "d"}]
        new = [{"id": "b"}, {"id": "d"}]
        d = diff(old, new, self._ids(old))
        self.assertEqual(d["deleted"], [0, 2])
        self.assertEqual(d["inserted"], [])
        self.assertEqual(d["moves"], [])
        self.assertEqual(d["reloaded"], [])

    def test_append_is_only_inserts(self):
        old = [{"id": "a"}, {"id": "b"}]
        new = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        d = diff(old, new, self._ids(old))
        self.assertEqual(d["inserted"], [2])
        self.assertEqual(d["deleted"], [])
        self.assertEqual(d["moves"], [])

    def test_single_remove_is_one_delete_no_reload(self):
        old = [{"id": "a"}, {"id": "b"}, {"id": "c"}]
        new = [{"id": "a"}, {"id": "c"}]
        d = diff(old, new, self._ids(old), self._equal)
        self.assertEqual(d["deleted"], [1])
        self.assertEqual(d["inserted"], [])
        self.assertEqual(d["moves"], [])
        self.assertEqual(d["reloaded"], [])

    def test_pure_reorder_is_moves_only(self):
        old = [{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "d"}]
        new = [{"id": "d"}, {"id": "a"}, {"id": "c"}, {"id": "b"}]
        d = diff(old, new, self._ids(old), self._equal)
        self.assertEqual(d["inserted"], [])
        self.assertEqual(d["deleted"], [])
        self.assertEqual(d["reloaded"], [])
        # old->new mapping: a 0->1, b 1->3, c 2->2, d 3->0. LIS of [3,0,2,1] = [0,2] (a,c kept). Moves: d(3->0), b(1->3).
        self.assertEqual(sorted((m["from"], m["to"]) for m in d["moves"]), [(1, 3), (3, 0)])

    def test_content_change_same_id_is_reload_only(self):
        old = [{"id": "a", "payload": 1}]
        new = [{"id": "a", "payload": 2}]
        d = diff(old, new, self._ids(old), self._equal)
        self.assertEqual(d["reloaded"], [0])
        self.assertEqual(d["inserted"], [])
        self.assertEqual(d["deleted"], [])
        self.assertEqual(d["moves"], [])

    def test_mixed_move_and_update(self):
        old = [{"id": "a", "payload": 1}, {"id": "b", "payload": 1}]
        new = [{"id": "b", "payload": 2}, {"id": "a", "payload": 1}]
        d = diff(old, new, self._ids(old), self._equal)
        # b changed => reload at new index 0; a moved 0->1.
        self.assertEqual(d["reloaded"], [0])
        self.assertEqual([(m["from"], m["to"]) for m in d["moves"]], [(0, 1)])
        self.assertEqual(d["inserted"], [])
        self.assertEqual(d["deleted"], [])

    def test_mixed_insert_delete_move(self):
        old = [{"id": "a"}, {"id": "b"}, {"id": "c"}, {"id": "e"}]
        new = [{"id": "c"}, {"id": "d"}, {"id": "a"}, {"id": "f"}]
        d = diff(old, new, self._ids(old), self._equal)
        # inserts: d@1, f@3 ; deletes: b(1), e(3); c and a common.
        # common old seq in new order: c=2, a=0 => [2,0]; LIS=[2] kept => a is a move 0->2.
        self.assertEqual(d["inserted"], [1, 3])
        self.assertEqual(sorted(d["deleted"]), [1, 3])
        self.assertEqual([(m["from"], m["to"]) for m in d["moves"]], [(0, 2)])


class HostListDiffHelperSourceContracts(unittest.TestCase):
    def test_helper_files_are_pure_foundation(self):
        header = (SOURCES / "HostListDiffHelper.h").read_text(encoding="utf-8")
        impl = (SOURCES / "HostListDiffHelper.m").read_text(encoding="utf-8")
        self.assertIn("#import <Foundation/Foundation.h>", header)
        self.assertIn("#import \"HostListDiffHelper.h\"", impl)
        for forbidden in ("#import <UIKit", "#import \"UIKit", "UIKit/UIKit"):
            self.assertNotIn(forbidden, header)
            self.assertNotIn(forbidden, impl)

    def test_helper_declares_documented_api(self):
        header = (SOURCES / "HostListDiffHelper.h").read_text(encoding="utf-8")
        self.assertIn("@interface HostListDiff", header)
        self.assertIn("insertedNewIndexes", header)
        self.assertIn("deletedOldIndexes", header)
        self.assertIn("moves", header)
        self.assertIn("reloadedNewIndexes", header)
        self.assertIn("isEmpty", header)
        self.assertIn("+ (HostListDiff *)diffFromOld:", header)
        self.assertIn("identityBlock", header)
        self.assertIn("isEqualBlock", header)

    def test_implementation_uses_lis_move_detection(self):
        impl = (SOURCES / "HostListDiffHelper.m").read_text(encoding="utf-8")
        # Core algorithm building blocks must be present and deterministic.
        self.assertIn("commonOldIndexForNew", impl)
        self.assertIn("dpLen", impl)
        self.assertIn("keptOldForLIS", impl)
        self.assertIn("@\"from\"", impl)
        self.assertIn("@\"to\"", impl)
        # Pointer fallback so nil identities don't collide.
        self.assertIn("__host_ptr", impl)


class MediaFavoritesIncrementalRefreshContracts(unittest.TestCase):
    """The MediaBrowserViewController favorites list is the integration page."""

    def setUp(self):
        self.body = (SOURCES / "MediaBrowserViewController.m").read_text(encoding="utf-8")

    def test_imports_diff_helper(self):
        self.assertIn("#import \"HostListDiffHelper.h\"", self.body)

    def test_uses_diff_helper_for_incremental_apply(self):
        self.assertIn("- (void)applyFavoriteEntriesIncremental", self.body)
        self.assertIn("[HostListDiffHelper diffFromOld:", self.body)

    def test_unfavorite_paths_use_incremental_apply_not_reload(self):
        # Both the context-menu unfavorite and the swipe unfavorite previously
        # called reloadFavoriteEntries + reloadData. They must now route through
        # the incremental diff apply.
        self.assertIn("[weakSelf applyFavoriteEntriesIncremental]", self.body)
        self.assertIn("[owner applyFavoriteEntriesIncremental];done(YES)", self.body)
        # The destructive single-entry unfavorite handlers must not retain their
        # old full-reload tails.
        self.assertNotIn(
            "[weakSelf reloadFavoriteEntries];[weakSelf.tableView reloadData]",
            self.body,
        )
        self.assertNotIn(
            "[owner reloadFavoriteEntries];[owner.tableView reloadData];done(YES)",
            self.body,
        )

    def test_batch_update_uses_coordinated_operations(self):
        self.assertIn("performBatchUpdates", self.body)
        self.assertIn("deleteRowsAtIndexPaths", self.body)
        self.assertIn("insertRowsAtIndexPaths", self.body)
        self.assertIn("moveRowAtIndexPath", self.body)
        self.assertIn("reloadRowsAtIndexPaths", self.body)
        # Reload safety: the incremental apply must not call reloadData inside
        # the batch update block (would conflict with the diff).
        apply_block = self.body.split("- (void)applyFavoriteEntriesIncremental")[1]
        end = apply_block.find("\n- (")
        if end < 0:
            end = len(apply_block)
        apply_block = apply_block[:end]
        batch = apply_block.split("performBatchUpdates:^")[1] if "performBatchUpdates:^" in apply_block else ""
        self.assertNotIn("reloadData", batch)

    def test_poster_prefetch_on_appear(self):
        self.assertIn("prefetchPosterURLs", self.body)
        # The favorites controller warms the cache via HostImageLoader on appear.
        self.assertIn("[HostImageLoader.shared prefetchPosterURLs:", self.body)

    def test_computeFavorite_entries_is_extracted(self):
        self.assertIn("- (NSArray<NSDictionary *> *)computeFavoriteEntries", self.body)


if __name__ == "__main__":
    unittest.main()
