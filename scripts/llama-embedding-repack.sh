#!/bin/sh
# Mirror llama.cpp's official per-platform binary tarball plus the pinned
# EmbeddingGemma GGUF weights as tar.zst assets rooted at opt/llama-embedding
# (extract at / to install into /opt/llama-embedding). One asset per platform
# carries both, matching the codetel llama-embedding test fixture's layout:
# native/ holds the llama.cpp libraries and tools, models/ the GGUF.
# usage: llama-embedding-repack.sh <version>   # <version> is the bNNNN tag
# env:
#   GH_TOKEN                   GitHub token (or use an authenticated gh CLI)
#   LLAMA_EMBEDDING_WORK       work dir (default .llama-embedding-work)
#   LLAMA_EMBEDDING_PLATFORMS  space-separated subset to build
#                            (default: linux-x64 linux-arm64 darwin-arm64)
set -eu
version="${1:?usage: llama-embedding-repack.sh <bNNNN-version>}"
work="${LLAMA_EMBEDDING_WORK:-$PWD/.llama-embedding-work}"
out="$work/out"
platforms="${LLAMA_EMBEDDING_PLATFORMS:-linux-x64 linux-arm64 darwin-arm64}"

# The GGUF is pinned test data (same revision/sha the consumers pin), not part
# of the tracked version: bump it here and force-rebuild the product.
gguf_file="embeddinggemma-300M-Q8_0.gguf"
gguf_revision="0f741b5a6585bd53aeb15cd1372c56f2a0f65e12"
gguf_sha256="b5ce9d77a3fc4b3b39ccb5643c36777911cc4eb46a66962eadfa3f5f60490d63"
gguf_url="https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/${gguf_revision}/${gguf_file}"

# Redistribution must include the Gemma terms and required notice. These are
# pinned text snapshots of Google's terms and incorporated prohibited-use
# policy, taken from a redistribution of this exact GGUF.
terms_revision="957b55764bd672f51240ac026e3a23ac9459ee3c"
terms_base="https://huggingface.co/ente-ai/embeddinggemma-300m-gguf/resolve/${terms_revision}"
terms_sha256="27d611613fb5b735e07ba071140b15f7904312dd9746ce0df804cf5ba431ac87"
policy_sha256="2fdf378073f14d0a88422dafc5c4be75d0327bd6766b105ca98c204ba3b9f2b3"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$script_dir/lib.sh"
rm -rf "$work"
mkdir -p "$out" "$work/dl"

ensure_cmds gh jq zstd # preinstalled on the runner images

base="https://github.com/ggml-org/llama.cpp/releases/download/${version}"

# Verify llama.cpp's GitHub-generated asset digests. The GGUF and terms files
# use pinned sha256 values.
release_json="$work/llama-release.json"
gh api "repos/ggml-org/llama.cpp/releases/tags/$version" >"$release_json"
gguf="$work/dl/$gguf_file"
fetch "$gguf_url" "$gguf" "$gguf_sha256"
terms="$work/dl/GEMMA_TERMS_OF_USE.txt"
policy="$work/dl/GEMMA_PROHIBITED_USE_POLICY.txt"
fetch "$terms_base/GEMMA_TERMS_OF_USE.txt" "$terms" "$terms_sha256"
fetch "$terms_base/GEMMA_PROHIBITED_USE_POLICY.txt" "$policy" "$policy_sha256"

host="$(uname -s)-$(uname -m)"
for platform in $platforms; do
	case "$platform" in
	linux-x64) classifier=ubuntu-x64; lib=libllama.so ;;
	linux-arm64) classifier=ubuntu-arm64; lib=libllama.so ;;
	darwin-arm64) classifier=macos-arm64; lib=libllama.dylib ;;
	*)
		echo "llama-embedding-repack.sh: unsupported platform '$platform'" >&2
		exit 1
		;;
	esac
	name="llama-${version}-bin-${classifier}.tar.gz"
	tgz="$work/dl/$name"
	fetch "$base/$name" "$tgz"
	upstream_sha=$(sha256_of "$tgz")
	asset_digest=$(jq -r --arg name "$name" \
		'.assets[] | select(.name == $name) | .digest // empty' "$release_json")
	case "$asset_digest" in
	"sha256:$upstream_sha") ;;
	*)
		echo "llama-embedding-repack.sh: digest mismatch for $name: got $upstream_sha, GitHub reports ${asset_digest:-<missing>}" >&2
		exit 1 ;;
	esac

	rm -rf "$work/stage"
	prefix="$work/stage/opt/llama-embedding"
	mkdir -p "$prefix/native" "$prefix/models"
	tar --strip-components=1 -xzf "$tgz" -C "$prefix/native"
	[ -f "$prefix/native/$lib" ] || {
		echo "llama-embedding-repack.sh: $name does not contain $lib" >&2
		exit 1
	}
	cp "$gguf" "$prefix/models/$gguf_file"
	cp "$terms" "$policy" "$prefix/"
	cat >"$prefix/NOTICE" <<'EOF'
Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms
EOF
	cat >"$prefix/MODIFICATIONS.md" <<'EOF'
# Modifications

This GGUF is a converted and quantized derivative of
`google/embeddinggemma-300m`. The conversion was published by ggml-org. This
release mirrors the GGUF byte-for-byte and does not further modify the model.
EOF

	{
		echo "product=llama-embedding"
		echo "version=$version"
		echo "platform=$platform"
		echo "upstream-url=$base/$name"
		echo "upstream-sha256=$upstream_sha"
		echo "gguf-url=$gguf_url"
		echo "gguf-sha256=$gguf_sha256"
		echo "gemma-terms=https://ai.google.dev/gemma/terms"
		echo "gemma-terms-snapshot=$terms_base/GEMMA_TERMS_OF_USE.txt"
		echo "gemma-terms-sha256=$terms_sha256"
		echo "gemma-policy-snapshot=$terms_base/GEMMA_PROHIBITED_USE_POLICY.txt"
		echo "gemma-policy-sha256=$policy_sha256"
		echo "recipe=repack of the upstream llama.cpp binary tarball + pinned EmbeddingGemma GGUF"
		true
	} >"$prefix/BUILD-INFO.txt"

	asset="$out/llama-embedding-${version}-${platform}.tar.zst"
	sh "$script_dir/pack.sh" "$work/stage" "$asset" opt

	# Re-extract and confirm the repack preserved the payload, then run a real
	# binary when the host matches the target.
	verify="$work/verify"
	verify_extract "$asset" "$verify"
	native="$verify/opt/llama-embedding/native"
	[ -f "$native/$lib" ] &&
		[ -f "$verify/opt/llama-embedding/models/$gguf_file" ] &&
		[ -f "$verify/opt/llama-embedding/GEMMA_TERMS_OF_USE.txt" ] &&
		[ -f "$verify/opt/llama-embedding/GEMMA_PROHIBITED_USE_POLICY.txt" ] &&
		[ -f "$verify/opt/llama-embedding/NOTICE" ] &&
		[ -f "$verify/opt/llama-embedding/MODIFICATIONS.md" ] || {
		echo "llama-embedding-repack.sh: packaged archive layout unexpected" >&2
		exit 1
	}
	case "$platform-$host" in
	linux-x64-Linux-x86_64 | linux-arm64-Linux-aarch64 | darwin-arm64-Darwin-arm64)
		cli="$native/llama-cli"
		[ -x "$cli" ] || {
			echo "llama-embedding-repack.sh: packaged archive is missing an executable llama-cli" >&2
			exit 1
		}
		ver_out=$(LD_LIBRARY_PATH="$native" DYLD_FALLBACK_LIBRARY_PATH="$native" \
			"$cli" --version 2>&1)
		echo "smoke: $ver_out"
		case "$ver_out" in
		*"build ${version#b}"*) ;;
		*)
			echo "llama-embedding-repack.sh: llama-cli build mismatch: got '$ver_out', want build ${version#b}" >&2
			exit 1
			;;
		esac
		;;
	*) echo "smoke: skipped run test (host $host cannot run $platform)" ;;
	esac
	echo "mirrored $asset"
done
