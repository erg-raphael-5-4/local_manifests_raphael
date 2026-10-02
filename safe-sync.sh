#!/bin/bash
#
# Sync the derp-17 tree without losing work.
#
# Every project in the tree is checked before repo touches it:
#  - local branches with commits that are on no remote are saved as git
#    bundles under $BACKUP_DIR
#  - uncommitted changes, commits on a detached HEAD and checkouts at a
#    manifest path that repo doesn't manage stop the sync
# After the sync, every saved branch tip is checked again, and anything
# that is no longer reachable is listed with the command to restore it.
#
#   .repo/local_manifests/safe-sync.sh            check, back up, sync
#   .repo/local_manifests/safe-sync.sh --check    check and back up only
#   JOBS=3 .repo/local_manifests/safe-sync.sh [extra repo sync args]
#

set -e

TOP="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
cd "$TOP"

BACKUP_DIR="${BACKUP_DIR:-$HOME/customrom/backups/sync-$(date +%Y%m%d-%H%M%S)}"
JOBS="${JOBS:-3}"
CHECK_ONLY=
SYNC_ARGS=()
for a in "$@"; do
    case "$a" in
        --check) CHECK_ONLY=1 ;;
        *) SYNC_ARGS+=("$a") ;;
    esac
done

mkdir -p "$BACKUP_DIR"
saved="$BACKUP_DIR/saved-branches.txt"
: > "$saved"
problems=0

echo ">> Checking $(repo list -a -p | wc -l) projects (backups in $BACKUP_DIR)"
while read -r p; do
    [ -e "$p/.git" ] || continue

    # A checkout repo doesn't manage gets in the way of the sync.
    if [ -d "$p/.git" ] && [ ! -L "$p/.git" ]; then
        echo "!! $p: not a repo checkout (a manual clone); move it out of the tree"
        problems=$((problems + 1))
        continue
    fi

    if [ -n "$(git -C "$p" status --porcelain --untracked-files=no)" ]; then
        echo "!! $p: uncommitted changes"
        problems=$((problems + 1))
    fi

    if ! git -C "$p" symbolic-ref -q HEAD >/dev/null &&
            [ -n "$(git -C "$p" rev-list -1 HEAD --not --remotes)" ]; then
        echo "!! $p: commits on a detached HEAD; put them on a branch"
        problems=$((problems + 1))
    fi

    git -C "$p" for-each-ref --format='%(refname:short) %(objectname)' refs/heads |
    while read -r b sha; do
        [ -n "$(git -C "$p" rev-list -1 "$b" --not --remotes)" ] || continue
        f="$BACKUP_DIR/$(echo "$p" | tr / _)__$(echo "$b" | tr / _).bundle"
        git -C "$p" bundle create -q "$f" "$b" --not --remotes
        echo "$p $b $sha $f" >> "$saved"
        echo "   saved $p $b ($(git -C "$p" rev-list --count "$b" --not --remotes) local-only)"
    done
done < <(repo list -a -p)

if [ "$problems" -gt 0 ]; then
    echo ">> $problems problem(s) found; not syncing"
    exit 1
fi
[ -n "$CHECK_ONLY" ] && { echo ">> Check passed; not syncing (--check)"; exit 0; }

# Everything that exists only locally is in a bundle now, so it's safe to
# let repo re-create git dirs whose remote changed.
echo ">> repo sync"
repo sync --force-sync --no-tags --no-clone-bundle -j"$JOBS" "${SYNC_ARGS[@]}"

echo ">> Verifying saved branches"
lost=0
while read -r p b sha f; do
    if git -C "$p" merge-base --is-ancestor "$sha" "$b" 2>/dev/null; then
        continue
    fi
    if git -C "$p" cat-file -e "$sha^{commit}" 2>/dev/null &&
            git -C "$p" branch -a --contains "$sha" 2>/dev/null | grep -q .; then
        continue
    fi
    echo "!! $p $b ($sha) is no longer on a branch; restore it with:"
    echo "     git -C $p fetch $f $b:$b"
    lost=$((lost + 1))
done < "$saved"
[ "$lost" -eq 0 ] && echo ">> All saved branches are intact"
