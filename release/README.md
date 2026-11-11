# Release Assets

This directory deliberately does **not** commit binaries: they are large, and
`BOOT.BIN` / `image.ub` embed GPL components whose distribution obligations are
discharged through GitHub Releases rather than git history. What is committed:

| File | Purpose |
|---|---|
| `RELEASE_NOTES_v16.md` | v16 release notes (paste straight into the GitHub Release) |
| `MD5SUMS.txt` | Checksums |
| `SHA256SUMS.txt` | Checksums |
| `v16/` | Assets to upload (local only, not committed) |
| `upload_release.sh` | Upload helper (works when a token is available) |

## Uploading — three options

### A. With a Personal Access Token (fully automated, recommended)

```bash
export GITHUB_TOKEN=ghp_xxxxxxxx
./upload_release.sh
```

### B. Via the web UI (no token needed)

1. Open https://github.com/palzhj/XJSM-P12-Z7000/releases/new
2. **Choose a tag** → `v16` → Create new tag
3. **Release title**: `v16 — Broadcast + 12-Engine XVC Remote JTAG (K7 programming verified)`
4. **Describe this release**: paste the whole of `RELEASE_NOTES_v16.md`
5. **Attach binaries**: drop in the 5 files from `v16/`
6. Tick `Set as the latest release` → Publish

### C. With the gh CLI

```bash
gh auth login
gh release create v16 v16/* \
  --title "v16 — Broadcast + 12-Engine XVC Remote JTAG (K7 programming verified)" \
  --notes-file RELEASE_NOTES_v16.md
```
