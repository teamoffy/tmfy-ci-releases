# shellcheck shell=sh
# Shared helpers for the build/release scripts — source, don't execute:
#   script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
#   # shellcheck source=/dev/null
#   . "$script_dir/lib.sh"

# sha256_of <file> — print the sha256 hex digest (sha256sum or macOS shasum).
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum -- "$1" | cut -d ' ' -f1
	else
		shasum -a 256 -- "$1" | cut -d ' ' -f1
	fi
}

# sha512_of <file> — print the sha512 hex digest.
sha512_of() {
	if command -v sha512sum >/dev/null 2>&1; then
		sha512sum -- "$1" | cut -d ' ' -f1
	else
		shasum -a 512 -- "$1" | cut -d ' ' -f1
	fi
}

# check_sha <file> [expected-sha256] — die on mismatch; no-op when unset/empty.
check_sha() {
	[ -n "${2:-}" ] || return 0
	actual=$(sha256_of "$1")
	if [ "$2" != "$actual" ]; then
		echo "check_sha: checksum mismatch for $1: expected $2, got $actual" >&2
		exit 1
	fi
}

# fetch <url> <dest> [expected-sha256] — download with retries, verify the
# optional checksum, and log "sha256  <url-basename>" to $UPSTREAM_SHA_LOG if set.
fetch() {
	curl -fsSL --retry 3 -o "$2" "$1"
	check_sha "$2" "${3:-}"
	if [ -n "${UPSTREAM_SHA_LOG:-}" ]; then
		echo "$(sha256_of "$2")  $(basename -- "$1")" >>"$UPSTREAM_SHA_LOG"
	fi
}

# fetch_flatcar <artifact-url> <dest> — download a Flatcar release artifact and
# verify it against the published <url>.DIGESTS sidecar (sha512 section). The
# .DIGESTS file groups digests under "# SHA512 DIGESTS" style headers, so the
# awk tracks which digest family it is reading. Logs the file's sha256 to
# $UPSTREAM_SHA_LOG when set (what we ship), independent of the sha512 check.
fetch_flatcar() {
	digests=$(mktemp "${TMPDIR:-/tmp}/flatcar-digests.XXXXXX")
	curl -fsSL --retry 3 -o "$digests" "$1.DIGESTS"
	expected=$(awk -v artifact="${1##*/}" '
		/^#/ { sha512 = tolower($0) ~ /sha512/; next }
		sha512 && $2 == artifact && length($1) == 128 && $1 !~ /[^0-9a-f]/ { print $1; found++ }
		END { if (found != 1) exit 1 }
	' "$digests")
	rm -f "$digests"
	curl -fsSL --retry 3 -o "$2" "$1"
	actual=$(sha512_of "$2")
	if [ "$actual" != "$expected" ]; then
		echo "fetch_flatcar: sha512 mismatch for $1: expected $expected, got $actual" >&2
		exit 1
	fi
	if [ -n "${UPSTREAM_SHA_LOG:-}" ]; then
		echo "$(sha256_of "$2")  $(basename -- "$1")" >>"$UPSTREAM_SHA_LOG"
	fi
}

# ncpu — processor count for parallel builds.
ncpu() { getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4; }

# require_linux <script-name> <why> — stop unless the host is Linux. The server
# products only ever ship to Linux runners, so a macOS run would exercise a
# different code path than CI for no benefit.
require_linux() {
	[ "$(uname -s)" = Linux ] || {
		printf '%s: Linux only (%s). Host is %s.\n' "$1" "$2" "$(uname -s)" >&2
		exit 1
	}
}

# ensure_cmds <cmd>... — install anything missing (apt on Linux, brew on macOS).
# The runner images already carry most of these; this is for local runs.
ensure_cmds() {
	missing=
	for c in "$@"; do
		command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
	done
	[ -n "$missing" ] || return 0
	if [ "$(uname -s)" = Linux ]; then
		sudo apt-get update
		# shellcheck disable=SC2086
		sudo apt-get install -y --no-install-recommends $missing
	else
		# shellcheck disable=SC2086
		brew install $missing
	fi
}

# setup_linux_toolchain — call after the script's apt install (needs lld).
# Prefers gcc-16 (newest in 26.04, vs the 15.x default), else falls back to the
# system compiler. Links via lld; -static-libgcc keeps shipped .so's free of a
# libgcc_s runtime dep.
setup_linux_toolchain() {
	if sudo apt-get install -y --no-install-recommends gcc-16 g++-16 >/dev/null 2>&1; then
		export CC=gcc-16 CXX=g++-16
	fi
	export LDFLAGS="${LDFLAGS:+$LDFLAGS }-fuse-ld=lld -static-libgcc"
}

# verify_extract <asset.tar.zst> <dir> — fresh-extract for post-pack checks.
verify_extract() {
	rm -rf "$2"
	mkdir -p "$2"
	tar --zstd -xf "$1" -C "$2"
}
