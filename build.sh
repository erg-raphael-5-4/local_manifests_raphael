#!/bin/bash
# DerpFest 17 for raphael: sync, install release keys, build.
#
#   ./build.sh                 sync, keys, build
#   SKIP_SYNC=1 ./build.sh     keys + build only (keeps local checkouts)
#   JOBS=6 ./build.sh          parallel jobs for mka (default 6)
#   DEBUG_ADB=1 ./build.sh     debug build: adb on from boot, no auth, adb root
#   BUILD_TYPE=user ./build.sh user build (default userdebug)
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
JOBS="${JOBS:-6}"
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
    JOBS=3 .repo/local_manifests/safe-sync.sh
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
mka derp -j"$JOBS"
