#!/usr/bin/env bash
# fix-host.sh - make PetaLinux 2022.2 build on a host that is newer than its
# supported distro list (tested on Ubuntu 26.04 / glibc 2.43 / GCC 15).
#
# Run AFTER the first `petalinux-build` attempt (build/tmp must exist) and
# BEFORE retrying the build.
#
#   ./tools/fix-host.sh /path/to/xvc/petalinux/xvc
#
set -euo pipefail

PROJ="${1:-$(cd "$(dirname "$0")/.." && pwd)/petalinux/xvc}"
TMP="$PROJ/build/tmp"

[ -d "$TMP" ] || { echo "error: $TMP not found - run petalinux-build once first"; exit 1; }

echo "[1/2] pointing bitbake hosttools at gcc-12 (GCC 15 breaks 2022.2 recipes)"
if [ -x /usr/bin/gcc-12 ]; then
    for t in gcc g++ cpp gcc-ar gcc-nm gcc-ranlib cc c++; do
        case "$t" in
            cc)     src=/usr/bin/gcc-12 ;;
            c++)    src=/usr/bin/g++-12 ;;
            *)      src=/usr/bin/$t-12 ;;
        esac
        [ -x "$src" ] && ln -sf "$src" "$TMP/hosttools/$t"
    done
    "$TMP/hosttools/gcc" --version | head -1
else
    echo "  gcc-12 not installed - skipping (apt install gcc-12 g++-12)"
fi

echo "[2/2] checking the pseudo / /run workaround"
grep -q PSEUDO_IGNORE_PATHS "$PROJ/build/conf/petalinuxbsp.conf" 2>/dev/null \
    && echo "  petalinuxbsp.conf already patched" \
    || echo "  WARNING: build/conf/petalinuxbsp.conf has no PSEUDO_IGNORE_PATHS override"

echo
echo "done. retry:  source /opt/Xilinx/petalinux/2022.2/settings.sh && petalinux-build"
