#!/usr/bin/env bash
# Sync Phantom data files from Zenodo (and the Phantom data/ tree) into this mirror.
# Files under 100 MB are committed as normal git blobs.
# Files >= 100 MB are uploaded as GitHub Release assets (tag: large-files).
# Do NOT use Git LFS.
#
# Usage:
#   ./sync_from_zenodo.sh [/path/to/phantom]
#
# Requires: curl, openssl, git, gh (for release upload of large files)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PHANTOM_DIR="${1:-${PHANTOM_DIR:-}}"
MAX_GIT_BYTES=$((100 * 1024 * 1024))
RELEASE_TAG="large-files"

if [[ -z "${PHANTOM_DIR}" ]]; then
  if [[ -d "${ROOT}/../phantom-clean" ]]; then
    PHANTOM_DIR="${ROOT}/../phantom-clean"
  elif [[ -d "${ROOT}/../phantom" ]]; then
    PHANTOM_DIR="${ROOT}/../phantom"
  else
    echo "Usage: $0 /path/to/phantom"
    exit 1
  fi
fi

echo "Phantom source: ${PHANTOM_DIR}"
echo "Mirror root:    ${ROOT}"

mkdir -p "${ROOT}/data"

# Zenodo record_id -> relative data directory (matches map_dir_to_web)
# record_id:destination (one destination per record; legacy MESA EOS lives on 13148447 with opacities)
declare -a ZENODO_MAP=(
  "13148447:data/eos/mesa_opac"
  "21712204:data/eos/mesa"
  "13163155:data/eos/shen"
  "13163286:data/eos/helmholtz"
  "13162225:data/forcing"
  "13162515:data/velfield"
  "13162815:data/galaxy_merger"
  "13164858:data/starcluster"
  "18615172:data/binarybh"
  "13842491:data/eos/lombardi"
  "20738843:data/star_data_files"
)

download_zenodo_record() {
  local recid="$1"
  local destdir="$2"
  local api="https://zenodo.org/api/records/${recid}"
  local json tmpfile key size checksum url outfile md5

  mkdir -p "${ROOT}/${destdir}"
  json="$(mktemp)"
  curl -fsL "${api}" -o "${json}"

  # Extract file entries: key, size, checksum, download link via python3
  python3 - "${json}" "${ROOT}" "${destdir}" "${MAX_GIT_BYTES}" <<'PY'
import json, os, sys, subprocess, hashlib

jsonfile, root, destdir, max_git = sys.argv[1:5]
max_git = int(max_git)
with open(jsonfile) as f:
    rec = json.load(f)

large = []
for fmeta in rec.get("files", []):
    key = fmeta["key"]
    size = int(fmeta["size"])
    checksum = fmeta.get("checksum", "")
    url = fmeta["links"]["self"]
    if not url.endswith("/content"):
        # older API style
        url = f"https://zenodo.org/records/{rec['id']}/files/{key}"
    else:
        # content link works with curl -L
        pass
    # Prefer the record files URL used by Phantom
    url = f"https://zenodo.org/records/{rec['id']}/files/{key}"
    out = os.path.join(root, destdir, key)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    print(f"  fetching {key} ({size/1e6:.1f} MB) -> {destdir}/")
    subprocess.check_call(["curl", "-fLk", url, "-o", out])
    if checksum.startswith("md5:"):
        expect = checksum.split(":", 1)[1]
        h = hashlib.md5()
        with open(out, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
        got = h.hexdigest()
        if got.lower() != expect.lower():
            raise SystemExit(f"MD5 mismatch for {key}: expected {expect}, got {got}")
        with open(out + ".md5", "w") as mf:
            mf.write(expect + "\n")
    if size >= max_git:
        large.append(out)

# write list of large files for the shell to upload
with open(os.path.join(root, ".large_files_tmp"), "a") as lf:
    for p in large:
        lf.write(p + "\n")
PY
  rm -f "${json}"
}

# Copy already-tracked small files from the Phantom data directory
echo "==> Copying tracked files from ${PHANTOM_DIR}/data"
if [[ -d "${PHANTOM_DIR}/data" ]]; then
  rsync -a --exclude='README' --exclude='*.md' \
    --exclude='*.o' --exclude='*.in' --exclude='*.setup' \
    --exclude='check_masunaga_vs_maxvals.f90' \
    "${PHANTOM_DIR}/data/" "${ROOT}/data/" || true
  # Prefer keeping READMEs from phantom that document remote files
  rsync -a --include='*/' --include='README' --exclude='*' \
    "${PHANTOM_DIR}/data/" "${ROOT}/data/" || true
fi

rm -f "${ROOT}/.large_files_tmp"
touch "${ROOT}/.large_files_tmp"

echo "==> Downloading Zenodo records"
seen_recid_dir=""
for entry in "${ZENODO_MAP[@]}"; do
  recid="${entry%%:*}"
  destdir="${entry#*:}"
  key="${recid}:${destdir}"
  # skip exact duplicate recid+destdir pairs
  if [[ " ${seen_recid_dir} " == *" ${key} "* ]]; then
    continue
  fi
  seen_recid_dir="${seen_recid_dir} ${key}"
  echo "-- record ${recid} -> ${destdir}"
  download_zenodo_record "${recid}" "${destdir}"
done

# Placeholders for large files in the git tree (actual bytes live in the release)
echo "==> Preparing git tree (files < 100 MB only)"
LARGE_DIR="${ROOT}/.large_release_assets"
mkdir -p "${LARGE_DIR}"
: > "${ROOT}/.gitignore"
cat >> "${ROOT}/.gitignore" <<'EOF'
.large_files_tmp
.large_release_assets/
EOF

if [[ -s "${ROOT}/.large_files_tmp" ]]; then
  while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    base="$(basename "${path}")"
    rel="${path#${ROOT}/}"
    echo "  large file -> release asset: ${base}"
    mv -f "${path}" "${LARGE_DIR}/${base}"
    # keep sidecar md5 next to placeholder if present
    if [[ -f "${path}.md5" ]]; then
      mv -f "${path}.md5" "${LARGE_DIR}/${base}.md5"
    fi
    mkdir -p "$(dirname "${path}")"
    cat > "${path}.RELEASE.txt" <<EOF
# ${base} is larger than 100 MB and is stored as a GitHub Release asset
# Download:
#   https://github.com/phantomSPH/phantom-datafiles/releases/download/${RELEASE_TAG}/${base}
EOF
  done < "${ROOT}/.large_files_tmp"
fi

echo "==> Done downloading. Review changes, then:"
echo "    cd ${ROOT}"
echo "    git add data .gitignore README.md sync_from_zenodo.sh"
echo "    git commit -m 'Populate data mirror from Zenodo'"
echo "    git push origin main"
echo "    # upload large files (if any):"
echo "    gh release create ${RELEASE_TAG} .large_release_assets/* -t '${RELEASE_TAG}' -n 'Data files larger than 100 MB' || \\"
echo "    gh release upload ${RELEASE_TAG} .large_release_assets/* --clobber"
