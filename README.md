# local_manifests for raphael (sm8150) DerpFest 16.2 build

Private repo-tool local manifest. To use:

```
cd <build-root>
git clone https://github.com/erg-raphael-5-4/local_manifests.git .repo/local_manifests
repo sync -j$(nproc)
```

What it does:
- Removes the `hardware/qcom/*` trees that collide with `hardware/qcom-caf/sm8150/*`
  at the Soong/Kati layer.
- Removes wrong-SoC trees (sdm845, sm7250) that we don't need on raphael.
- Overrides three upstream LineageOS projects with private forks at
  `erg-raphael-5-4` for the trees where we maintain device-specific patches
  (sm8150 display, sm8150 media, sm8350 audio).

The fork repos and this manifest repo are private; clone via a PAT in
`~/.netrc` or via a `git config --global url.<token>@github.com/.insteadOf
https://github.com/` rewrite.

Each forked project's commit history in the erg-raphael-5-4 organisation
describes its patches.
