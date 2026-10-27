# Cross-source search interaction

## Behavior

- The horizontal filter strip includes All, resource collections, and discovered
  searchable providers. Counts come from stored results after provider-scoped
  deduplication, never from guessed upstream totals. Filtering does not restart
  or expand a search. The global cap remains 100, with at most three active
  source jobs and sequential provider requests inside each source.
- A provider response is appended immediately. Results are clickable while other
  jobs run. `MediaSearchResults.h` shares filtering/deduplication with Foundation
  tests and uses structured provider/film identities to avoid cross-site ID and
  delimiter collisions.
- Results use reusable poster rows with title, available year/area/type/remarks,
  and collection/provider labels. Missing metadata has an explicit placeholder.
  Thumbnails reuse the shared bounded 192px image loader; the search page does
  not create a second cache or request queue.
- No results, source failure, partial failure, stopped plugin, cancellation and
  result cap are separate states. Providers retain their own state and error.
  Stopped plugins still require a user action; filtering does not start them.
- Each filter has a reading position. Before a reload or navigation, the top
  visible film identity and its pixel offset are retained. Returning from detail
  restores the keyword, filter and film anchor even if earlier sources appended
  results. Jobs may finish while details are open; table updates wait until the
  search page returns. Permanently leaving the page cancels jobs.
- Changing the input cancels readiness/network jobs and advances the generation
  immediately. Old callbacks must match both generation and job identity to
  apply. Press Search submits the new query; while editing, the label explicitly
  says any retained rows belong to the previous search. Clearing the query clears
  old rows/counts/filters. Search history remains opt-in and local.

## Validation

- `python3 -m unittest discover -s Tests -p 'test_*.py'`
- `Tests/test_native_search_results.py` compiles/runs the actual Foundation
  helper on macOS; it is skipped when Foundation is unavailable.
- UI smoke adds `21a-global-search-all` and `21b-global-search-station` fixtures,
  checking count/filter isolation, clickable partial results, detail return
  state, late-result application and stale-job rejection after an input change.
  These are controlled UI fixtures, not external movie/playback verification.
- Device acceptance remains necessary for IME/keyboard, narrow screens, largest
  Dynamic Type sizes, repeated navigation/interactive back, and scrolling while
  several providers return together. No device performance numbers are claimed.

No subscriptions, source configuration formats, player implementations or user
history migration are changed by this work.
