# local_manifests for raphael (DerpFest 17)

Local manifest for building DerpFest 17 for the Redmi K20 Pro / Mi 9T Pro
(raphael, sm8150). The `lineage-23.2` branch holds the LineageOS 23.2
manifest.

```
cd <build-root>
repo init -u https://github.com/DerpFest-AOSP/android_manifest.git -b 17 --git-lfs --no-clone-bundle
git clone -b derp-17 https://github.com/erg-raphael-5-4/local_manifests_raphael.git .repo/local_manifests
.repo/local_manifests/safe-sync.sh
```

What it does:
- Removes the `hardware/qcom/*` trees that collide with
  `hardware/qcom-caf/sm8150/*`, and wrong-SoC trees we don't need.
- Uses `erg-raphael-5-4` forks, on their `derp-17` branches, for every
  project we carry patches in: the device and vendor trees, the kernel,
  MIUI Camera (`device/xiaomi/miuicamera`, `vendor/xiaomi/miuicamera`),
  the sm8150 display/media/audio HALs, the NXP NFC HAL, `hardware/xiaomi`
  and `hardware/interfaces`.

Each fork's history describes its patches.

## Syncing without losing work

Use `safe-sync.sh` instead of a bare `repo sync`. Before repo touches the
tree it:
- saves every local branch with commits that are on no remote as a git
  bundle under `~/customrom/backups/sync-<date>/`
- stops if a project has uncommitted changes, commits on a detached HEAD,
  or a checkout at a manifest path that repo doesn't manage

Then it runs `repo sync --force-sync`, and afterwards checks that every
saved branch tip is still reachable; anything that isn't is listed with the
command that restores it from its bundle.

```
.repo/local_manifests/safe-sync.sh --check   # check and back up only
JOBS=3 .repo/local_manifests/safe-sync.sh    # check, back up, sync
```

## Building

`build.sh` syncs through safe-sync.sh, installs the release keys from
`~/.android-certs` and builds. Link it into the build root once:

```
ln -s .repo/local_manifests/build.sh build.sh
./build.sh                      # sync, keys, userdebug build
BUILD_TYPE=user ./build.sh      # user build
SKIP_SYNC=1 BUILD_TYPE=user ./build.sh
```

Work belongs on a fork listed here and pushed to its `derp-17` branch; a
project that isn't listed follows upstream on every sync.
