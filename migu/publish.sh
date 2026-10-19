#!/usr/bin/env bash
# Publish only validated data. Never force-push or replay over concurrent Migu edits.
set -euo pipefail

migu_tested_sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
git add -- migu.m3u8 migu-status.json
while IFS= read -r -d '' migu_staged_path; do
  case "$migu_staged_path" in
    migu.m3u8|migu-status.json) ;;
    *) echo 'Refusing to publish unrelated staged files.'; exit 1 ;;
  esac
done < <(git diff --cached --name-only -z)
if git diff --cached --quiet; then
  echo 'No catalogue change.'
  exit 0
fi
git diff --cached --check
git config user.name 'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git commit -m 'Refresh validated Migu playlist'

git fetch --no-tags --depth=2 origin main
migu_remote_sha="$(git rev-parse FETCH_HEAD)"
if [ "$migu_remote_sha" != "$migu_tested_sha" ]; then
  if ! git diff --quiet "$migu_tested_sha" "$migu_remote_sha" -- \
    update_migu.py migu.m3u8 migu-status.json migu tests/migu .github/workflows/migu.yml; then
    echo 'Migu code, policy or catalogue changed remotely; retain remote data and retry from a fresh revision.'
    exit 1
  fi
  # An explicit upstream works with the shallow Actions checkout. Only our data
  # commit is replayed; unrelated remote commits and files remain intact.
  git rebase --onto "$migu_remote_sha" "$migu_tested_sha"
fi
git push origin HEAD:main
