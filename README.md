# phantom-datafiles

Backup copy of all data files Phantom may download at runtime (EOS tables,
velocity cubes, galaxy ICs, etc.).

Phantom tries Zenodo first, then falls back to this repository if Zenodo is
unreachable.

## Layout

- `data/` mirrors the Phantom `data/` tree
- Files **under 100 MB** are normal git blobs
- Files **≥ 100 MB** (`eos_binary_table.dat`, `galaxiesP25e5.dat`) are GitHub
  Release assets under the `large-files` tag (no Git LFS)

## Updating the mirror

From a checkout of this repo:

```bash
./sync_from_zenodo.sh /path/to/phantom
git add data .gitignore sync_from_zenodo.sh README.md
git commit -m "Update data mirror from Zenodo"
git push origin main
# upload large files if needed:
gh release create large-files .large_release_assets/* \
  -t large-files -n "Data files larger than 100 MB" \
  || gh release upload large-files .large_release_assets/* --clobber
```

The same sync script is also available in the Phantom tree as
`scripts/sync_phantom_datafiles.sh`.
