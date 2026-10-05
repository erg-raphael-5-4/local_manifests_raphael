#!/bin/bash
# DerpFest 17 for raphael: sync, install release keys, build.
#
#   ./build.sh                 sync, keys, build
#   SKIP_SYNC=1 ./build.sh     keys + build only (keeps local checkouts)
#   JOBS=6 ./build.sh          parallel jobs for mka (default 1)
#   DEBUG_ADB=1 ./build.sh     debug build: adb on from boot, no auth, adb root
#   BUILD_TYPE=user ./build.sh user build (default userdebug)
#
# The build runs at the lowest CPU and IO priority, in a systemd user scope
# whose memory is capped (MEM_HIGH throttles it, MEM_MAX is where the kernel
# starts swapping it out or OOM-kills it instead of a desktop app), so the
# machine stays usable while it builds. If the build dies from an OOM kill it
# is resumed with fewer jobs (12 -> 8 -> 5 -> 4 ...), up to MAX_TRIES attempts;
# any other failure stops the script, unless RETRY_ANY=1, which resumes after
# every failure.
#   MEM_HIGH=16G MEM_MAX=20G MAX_TRIES=5 GOMEMLIMIT=12GiB GOGC=50 (defaults)
# The output of each attempt is in out/build-<date>-<attempt>.log.
#
# The sync goes through .repo/local_manifests/safe-sync.sh, which backs up
# local-only branches and stops on unsaved work first. This script lives in
# the local manifest repo; <build-root>/build.sh is a symlink to it.
#
# Release keys live in ~/.android-certs (created once, never overwritten) and
# are copied into vendor/lineage/signing/keys, which derpfest.mk signs with.
# Keep ~/.android-certs backed up: builds signed with other keys can't be
# dirty-flashed over these.

set -e

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "$TOP" in */.repo/local_manifests) TOP="${TOP%/.repo/local_manifests}" ;; esac
JOBS="${JOBS:-1}"
MAX_TRIES="${MAX_TRIES:-5}"
MEM_HIGH="${MEM_HIGH:-16G}"
MEM_MAX="${MEM_MAX:-20G}"
export GOMEMLIMIT="${GOMEMLIMIT:-12GiB}"
export GOGC="${GOGC:-50}"
BUILD_TYPE="${BUILD_TYPE:-userdebug}"
case "$BUILD_TYPE" in
    user|userdebug|eng) ;;
    *) echo "BUILD_TYPE must be user, userdebug or eng" >&2; exit 1 ;;
esac
CERTS="${CERTS:-$HOME/.android-certs}"
KEYS_DIR="$TOP/vendor/lineage/signing/keys"
KEY_SUBJECT='/C=IN/ST=India/L=India/O=ergdev/OU=RaphGhost/CN=ergdev'
KEY_NAMES="releasekey platform shared media networkstack nfc sdk_sandbox bluetooth otakey"

cd "$TOP"

if [ -z "$SKIP_SYNC" ]; then
    repo init -u https://github.com/DerpFest-AOSP/android_manifest.git -b 17 --git-lfs --no-clone-bundle
    # Backs up local-only branches and stops on uncommitted or unsaved work
    # before syncing (.repo/local_manifests/safe-sync.sh).
    JOBS=3 nice -n 19 ionice -c 3 .repo/local_manifests/safe-sync.sh
fi

# Release keys
mkdir -p "$CERTS"
chmod 700 "$CERTS"
for k in $KEY_NAMES; do
    if [ ! -f "$CERTS/$k.pk8" ]; then
        echo "Generating $k key in $CERTS"
        (cd "$CERTS" && echo | "$TOP/development/tools/make_key" "$k" "$KEY_SUBJECT" >/dev/null 2>&1) || true
        [ -f "$CERTS/$k.pk8" ] || { echo "Failed to generate $k key" >&2; exit 1; }
    fi
done
mkdir -p "$KEYS_DIR"
for k in $KEY_NAMES; do
    cp "$CERTS/$k.pk8" "$CERTS/$k.x509.pem" "$KEYS_DIR/"
done
# sepolicy's keys.conf maps @RELEASE to <default cert dir>/testkey, i.e. the
# key ordinary apps are signed with. With inline signing that is releasekey.
cp "$CERTS/releasekey.pk8" "$KEYS_DIR/testkey.pk8"
cp "$CERTS/releasekey.x509.pem" "$KEYS_DIR/testkey.x509.pem"
echo "Release keys installed in $KEYS_DIR"

# Build
unset -f grep 2>/dev/null || true
if [ -n "$DEBUG_ADB" ]; then
    export WITH_ADB_INSECURE=true
else
    unset WITH_ADB_INSECURE
fi
source build/envsetup.sh
lunch lineage_raphael-cp2a-"$BUILD_TYPE"

# Run a command at idle priority, inside a memory-capped scope when a systemd
# user session is available.
lowprio() {
    if systemd-run --user --scope -q true 2>/dev/null; then
        systemd-run --user --scope -q -p MemoryHigh="$MEM_HIGH" -p MemoryMax="$MEM_MAX" \
            -p CPUWeight=10 -p IOWeight=10 nice -n 19 ionice -c 3 "$@"
    else
        nice -n 19 ionice -c 3 "$@"
    fi
}

# An attempt counts as OOM-killed when the kernel's OOM kill counter moved or
# the log shows a killed process or a Java heap exhaustion.
oom_kills() { awk '/^oom_kill /{print $2}' /proc/vmstat; }
oom_in_log() {
    grep -qE 'signal: killed|Killed$|exit status 137|OutOfMemoryError|Cannot allocate memory|fatal error: out of memory' "$1"
}

# pipefail only from here: envsetup.sh and lunch have pipelines that fail
# harmlessly, and with set -e that would end the script.
set -o pipefail
stamp="$(date +%Y%m%d-%H%M%S)"
mkdir -p out
try=1
while :; do
    log="out/build-$stamp-$try.log"
    before="$(oom_kills)"
    echo ">> Build attempt $try/$MAX_TRIES (-j$JOBS, log $log)"
    if lowprio bash -c 'source build/envsetup.sh >/dev/null &&
            lunch lineage_raphael-cp2a-"$1" >/dev/null && mka derp -j"$2"' _ "$BUILD_TYPE" "$JOBS" \
            2>&1 | tee "$log"; then
        echo ">> Build finished on attempt $try"
        break
    fi
    if [ "$(oom_kills)" != "$before" ] || oom_in_log "$log"; then
        why="OOM-killed"
        # Fewer jobs next time: 12 -> 8 -> 5 -> 4 -> 3 -> 2 -> 1.
        case "$JOBS" in
            1|2) [ "$JOBS" -gt 1 ] && JOBS=1 ;;
            3|4) JOBS=$((JOBS - 1)) ;;
            *) JOBS=$(( JOBS * 2 / 3 )); [ "$JOBS" -lt 4 ] && JOBS=4 ;;
        esac
    elif [ "${RETRY_ANY:-0}" = 1 ]; then
        why="failed"
    else
        echo ">> Build failed (not an OOM kill); see $log" >&2
        exit 1
    fi
    if [ "$try" -ge "$MAX_TRIES" ]; then
        echo ">> Build $why on attempt $try/$MAX_TRIES; giving up (see $log)" >&2
        exit 1
    fi
    echo ">> Build $why; resuming with -j$JOBS in 60 s"
    try=$((try + 1))
    sleep 60
done
