# `.platform/` — branch boundary bookkeeping

`main` builds the Linux / Windows desktop app; `android` builds the Android
app. Both share `lib/` and `rust/`; only the files listed in
`android-owned.txt` differ by presence.

## Why the manifest exists

`main` has no `android/` directory, no mobile widgets and no Android tests. If
you run `git merge main` on the `android` branch, git sees that *the branch
did not modify* those paths and **deletes them silently** — no conflict, no
warning, and the branch can no longer build an APK.

`scripts/sync-from-main.sh` merges and then restores every listed path from
the pre-merge tip, which covers both "restore a deleted file" and "keep the
branch's own version".

## Maintaining the list

Whenever you add a file that only the Android branch should have, append its
path (file or directory) to `android-owned.txt` in the same commit.

Generate a candidate list with:

```bash
comm -23 <(git ls-tree -r --name-only android | sort) \
         <(git ls-tree -r --name-only main | sort)
```

Files that exist on **both** branches with different content must NOT be
listed here — that would silently discard `main`'s change. Those are handled
by the `PlatformHost` seam instead (see `lib/platform/platform_host.dart`).
