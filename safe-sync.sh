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
# Then every project with a local $BRANCH branch is put back on it: repo
# leaves projects on a detached HEAD at the manifest revision, so without
# this the build would miss commits that are only on the local branch. If
# the remote branch moved, the local-only commits are rebased onto it. The
# branch is set to track the remote, so the next repo sync rebases it.
#
# Last, forks listed in upstreams.txt (path, upstream URL, upstream branch)
# get the upstream's new commits merged into their $BRANCH branch. Nothing
# is pushed; push after the build has been tested. A merge that conflicts is
# aborted and reported, and the project is left as it was.
#
#   .repo/local_manifests/safe-sync.sh                  check, back up, sync, merge upstreams
#   .repo/local_manifests/safe-sync.sh --check          check and back up only
#   .repo/local_manifests/safe-sync.sh --upstream-only  check, back up, merge upstreams (no repo sync)
#   NO_UPSTREAM=1 .repo/local_manifests/safe-sync.sh    skip the upstream merges
#   JOBS=3 .repo/local_manifests/safe-sync.sh [extra repo sync args]
#

set -e

TOP="$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)"
cd "$TOP"

BACKUP_DIR="${BACKUP_DIR:-$HOME/customrom/backups/sync-$(date +%Y%m%d-%H%M%S)}"
JOBS="${JOBS:-3}"
BRANCH="${BRANCH:-derp-17}"
UPSTREAMS="$TOP/.repo/local_manifests/upstreams.txt"
CHECK_ONLY=
UPSTREAM_ONLY=
SYNC_ARGS=()
for a in "$@"; do
    case "$a" in
        --check) CHECK_ONLY=1 ;;
        --upstream-only) UPSTREAM_ONLY=1 ;;
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

if [ -z "$UPSTREAM_ONLY" ]; then
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
fi

# Put every project that has a local $BRANCH back on it.
restore_branches() {
    echo ">> Checking out local $BRANCH branches"
    local p remote head
    while read -r p; do
        [ -e "$p/.git" ] || continue
        git -C "$p" show-ref -q --verify "refs/heads/$BRANCH" || continue
        remote="$(git -C "$p" remote | head -n1)"
        if git -C "$p" show-ref -q --verify "refs/remotes/$remote/$BRANCH" &&
                [ -z "$(git -C "$p" config "branch.$BRANCH.merge")" ]; then
            git -C "$p" branch -q -u "$remote/$BRANCH" "$BRANCH"
        fi
        [ "$(git -C "$p" symbolic-ref -q --short HEAD)" = "$BRANCH" ] && continue
        head="$(git -C "$p" rev-parse HEAD)"
        if git -C "$p" merge-base --is-ancestor "$head" "$BRANCH"; then
            git -C "$p" checkout -q "$BRANCH"
        elif git -C "$p" merge-base --is-ancestor "$BRANCH" "$head"; then
            git -C "$p" checkout -q -B "$BRANCH" "$head"
        elif git -C "$p" rebase -q "$head" "$BRANCH" >/dev/null 2>&1; then
            echo "   $p: rebased the local $BRANCH commits onto $(git -C "$p" rev-parse --short "$head")"
        else
            git -C "$p" rebase --abort 2>/dev/null || true
            git -C "$p" checkout -q --detach "$head"
            echo "!! $p: local $BRANCH doesn't rebase onto $(git -C "$p" rev-parse --short "$head"); fix it by hand"
            restore_problems=$((restore_problems + 1))
            continue
        fi
        echo "   $p: on $BRANCH ($(git -C "$p" rev-parse --short HEAD))"
    done < <(repo list -a -p)
}

# Merge new upstream commits into the forks listed in upstreams.txt.
merge_upstreams() {
    [ -f "$UPSTREAMS" ] || return 0
    echo ">> Merging upstream changes into $BRANCH"
    local p url ub ref n
    while read -r p url ub; do
        case "$p" in ''|'#'*) continue ;; esac
        if [ ! -e "$p/.git" ]; then
            echo "!! $p: not checked out"
            upstream_problems=$((upstream_problems + 1))
            continue
        fi
        if [ "$(git -C "$p" symbolic-ref -q --short HEAD)" != "$BRANCH" ]; then
            git -C "$p" checkout -q -B "$BRANCH" HEAD
        fi
        ref="refs/remotes/upstream/$ub"
        if ! git -C "$p" fetch -q --no-tags "$url" "+refs/heads/$ub:$ref"; then
            echo "!! $p: can't fetch $url $ub"
            upstream_problems=$((upstream_problems + 1))
            continue
        fi
        # A shallow clone may not reach the common ancestor yet.
        if [ "$(git -C "$p" rev-parse --is-shallow-repository)" = true ] &&
                ! git -C "$p" merge-base HEAD "$ref" >/dev/null; then
            git -C "$p" fetch -q --no-tags --unshallow "$url" "+refs/heads/$ub:$ref" || true
        fi
        if git -C "$p" merge-base --is-ancestor "$ref" HEAD; then
            echo "   $p: up to date with ${url#https://github.com/}@$ub"
            continue
        fi
        n="$(git -C "$p" rev-list --count "HEAD..$ref")"
        if git -C "$p" merge -q --no-edit -m "Merge ${url#https://github.com/} $ub into $BRANCH" "$ref" >/dev/null 2>&1; then
            echo "   $p: merged $n upstream commit(s) from ${url#https://github.com/}@$ub"
            upstream_merged=$((upstream_merged + 1))
        else
            echo "!! $p: merging $n commit(s) from ${url#https://github.com/}@$ub conflicts in:"
            git -C "$p" diff --name-only --diff-filter=U | sed 's/^/     /'
            git -C "$p" merge --abort 2>/dev/null || true
            upstream_problems=$((upstream_problems + 1))
        fi
    done < "$UPSTREAMS"
}

restore_problems=0
upstream_problems=0
upstream_merged=0
restore_branches
[ -z "$NO_UPSTREAM" ] && merge_upstreams
if [ -z "$NO_UPSTREAM" ] && [ -f "$UPSTREAMS" ]; then
    echo ">> Upstreams: $upstream_merged merged, $upstream_problems problem(s); nothing pushed"
fi
[ "$restore_problems" -eq 0 ] && [ "$upstream_problems" -eq 0 ] || exit 1
