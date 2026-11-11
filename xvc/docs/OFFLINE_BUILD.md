# PetaLinux Offline Build (Download Once, Reuse Locally)

> Created: 2026-11-03
> Applies to: PetaLinux 2023.1 / Yocto kirkstone

---

## 1. Why every build downloads again

Yocto's `do_fetch` task does three things for **every** recipe:

```
① Check whether the source pointed to by SRC_URI is already in DL_DIR
② If it is, verify the checksum (tarball) or ls-remote (git)
③ If it is not, download from upstream
```

**The problem is ②**: even if the source is already local, Yocto still:

- For **tarballs**: downloads the `.md5`/`.sha256` checksum files to confirm nothing changed
- For **git**: runs `git ls-remote` to confirm the commit still exists

When the network is slow or upstream has changed, this step fails → the build aborts.

**Measured**: `u-boot-xlnx`'s `do_fetch` contacts github.com every time to confirm the commit.

---

## 2. The solution

Append the following to the end of `build/conf/local.conf`:

```conf
# Register the local DL_DIR as a PREMIRROR (check local first when fetching)
INHERIT += "own-mirrors"
SOURCE_MIRROR_URL = "file://${DL_DIR}"
BB_GENERATE_MIRROR_TARBALLS = "1"

# Forbid the network outright: a missing package errors immediately instead of silently re-downloading
BB_NO_NETWORK = "1"
BB_FETCH_PREMIRRORONLY = "1"

# Shared sstate (reuse build artifacts across projects)
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache-shared"
```

### What the three variables do

| Variable | Effect |
|---|---|
| `own-mirrors` + `SOURCE_MIRROR_URL` | Treats `DL_DIR` as a mirror source, so fetch looks locally first |
| `BB_NO_NETWORK = "1"` | Blocks all network access (error if a package is missing)|
| `BB_FETCH_PREMIRRORONLY = "1"` | Fetches only from PREMIRROR, never falls back upstream |

---

## 3. Current cache size (measured on this machine)

```
$ du -sh build/downloads
17G	build/downloads

$ ls build/downloads | wc -l
470                          # archives / patches

$ ls build/downloads/git2 | wc -l
169                          # git bare repositories
```

---

## 4. Verifying offline operation

```bash
source /opt/Xilinx/petalinux/2023.1/settings.sh

# Test a tarball-style recipe
petalinux-build -c zlib -x do_fetch
# → Succeeded ✓

# Test a git-style recipe
petalinux-build -c u-boot-xlnx -x do_fetch
# → Succeeded ✓
```

**Measured result**: both succeed under `BB_NO_NETWORK=1` ✓

---

## 5. Reusing the cache in a new project

`DL_DIR` is `${TOPDIR}/downloads` (per project). To reuse the 17 GB cache in a new project,
**copy with hard links**: no extra space and no time cost:

```bash
# 1. Create a new project
petalinux-create -t project -n xvc3 --template zynq
cd xvc3

# 2. Hard-link the old cache (same partition, completes in seconds, 0 bytes of extra usage)
cp -al ~/work/xvc2/build/downloads ./build/downloads

# 3. Copy sstate
cp -al ~/work/xvc2/build/sstate-cache ./build/sstate-cache

# 4. Copy the offline configuration
cat >> build/conf/local.conf <<'CONF'
INHERIT += "own-mirrors"
SOURCE_MIRROR_URL = "file://${DL_DIR}"
BB_GENERATE_MIRROR_TARBALLS = "1"
BB_NO_NETWORK = "1"
BB_FETCH_PREMIRRORONLY = "1"
CONF
```

`cp -al` requires the source and destination to be on the **same filesystem** (fine under `~/work`).

---

## 6. First build (network required)

To **create** a new cache (for example after switching PetaLinux versions), temporarily comment out:

```conf
# BB_NO_NETWORK = "1"
# BB_FETCH_PREMIRRORONLY = "1"
```

Once the first build completes, the cache fills itself automatically; just restore these two lines.

---

## 7. Common errors

| Error | Cause | Fix |
|---|---|---|
| `undefined task do_fetch` | recipe name misspelled | `bitbake -s \| grep <name>` |
| `No checksum found` | new package has no checksum | remove `BB_NO_NETWORK` so it downloads once |
| `Unable to connect to bitbake server` | leftover lock from a previous build | delete `build/bitbake.lock` + `build/cache/prserv.sqlite3*` |

### Clearing the lock (when a build hangs)

```bash
pkill -9 -f bitbake
rm -rf build/bitbake.lock build/bitbake.sock build/cache/prserv.sqlite3*
```

---

## 8. This project's actual configuration

End of `~/work/xvc2/build/conf/local.conf`:

```conf
INHERIT += "own-mirrors"
SOURCE_MIRROR_URL = "file://${DL_DIR}"
BB_GENERATE_MIRROR_TARBALLS = "1"
BB_NO_NETWORK = "1"
BB_FETCH_PREMIRRORONLY = "1"
SSTATE_DIR ?= "${TOPDIR}/../sstate-cache-shared"
```

Backup: `local.conf.bak.<timestamp>`

---

## 9. Before vs. after

| Scenario | Before | After |
|---|---|---|
| Does `do_fetch` access the network | ✅ every time | ❌ never |
| When an upstream repository changes | ❌ build fails | ✅ unaffected |
| Offline build | ❌ fails | ✅ succeeds |
| First build | network required | network required (one time) |
| Subsequent builds | network required | **fully offline** |
