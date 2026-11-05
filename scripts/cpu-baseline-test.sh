#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/.."
. scripts/lib.sh

check_baseline() {
	CFLAGS=-O3
	CXXFLAGS=-O2
	setup_cpu_baseline "$1"
	[ "$CPU_BASELINE" = "$2" ]
	[ "$CPU_BASELINE_FLAGS" = "$4" ]
	[ "$CPU_BASELINE_RUST_CPU" = "$3" ]
	[ "$CFLAGS" = "-O3 $CPU_BASELINE_FLAGS" ]
	[ "$CXXFLAGS" = "-O2 $CPU_BASELINE_FLAGS" ]
	sh -eu -c '[ "$CFLAGS" = "-O3 $CPU_BASELINE_FLAGS" ] && [ "$CXXFLAGS" = "-O2 $CPU_BASELINE_FLAGS" ]'
}

check_baseline linux-x64 x86-64-v3 x86-64-v3 '-march=x86-64-v3 -mtune=generic'
check_baseline linux-arm64 armv8-a generic '-march=armv8-a -mtune=generic'
check_baseline darwin-arm64 apple-m1 apple-m1 '-mcpu=apple-m1'
unset CFLAGS CXXFLAGS
setup_cpu_baseline linux-x64
[ "$CFLAGS" = "-O3 $CPU_BASELINE_FLAGS" ]
[ "$CXXFLAGS" = "-O3 $CPU_BASELINE_FLAGS" ]
if (setup_cpu_baseline linux-riscv64 >/dev/null 2>&1); then
	printf '%s\n' 'unsupported CPU baseline was accepted' >&2
	exit 1
fi
if (setup_cpu_baseline darwin-arm64 apple-crypto >/dev/null 2>&1); then
	printf '%s\n' 'unsupported Apple arm64 profile was accepted' >&2
	exit 1
fi

for product in aws-lc zlib-ng zstd libgit2 postgres valkey sqlite; do
	grep -Fqx "setup_cpu_baseline \"\$platform\"" "$script_dir/$product-build.sh"
	grep -Fq "echo \"cpu-baseline=\$CPU_BASELINE\"" "$script_dir/$product-build.sh"
done
awk '
  /^make .*\/pgvector"/ {
    calls++
    if (index($0, "OPTFLAGS=\"$CPU_BASELINE_FLAGS\"") == 0) exit 1
  }
  END { if (calls != 2) exit 1 }
' "$script_dir/postgres-build.sh"
grep -Fq -- '-DWITH_NATIVE_INSTRUCTIONS=OFF' "$script_dir/zlib-ng-build.sh"
grep -Fq -- '-DWITH_RUNTIME_CPU_DETECTION=ON' "$script_dir/zlib-ng-build.sh"
grep -Fq "target-cpu=\$CPU_BASELINE_RUST_CPU" "$script_dir/valkey-build.sh"

case "$(uname -s)-$(uname -m)" in
Linux-x86_64) host_platform=linux-x64 ;;
Linux-aarch64) host_platform=linux-arm64 ;;
Darwin-arm64) host_platform=darwin-arm64 ;;
*)
	printf '%s\n' 'unsupported test host' >&2
	exit 1
	;;
esac
CFLAGS='' CXXFLAGS=''
setup_cpu_baseline "$host_platform"
compile_probe() {
	# These options come from setup_cpu_baseline and contain no shell syntax.
	# shellcheck disable=SC2086
	"${CC:-cc}" $CFLAGS -x c -fsyntax-only -
}
case "$host_platform" in
linux-x64)
	forbidden_features='#if defined(__AVX512F__) || defined(__AVX512BW__) || defined(__AVX512CD__) || defined(__AVX512DQ__) || defined(__AVX512VL__)'
	;;
linux-arm64)
	forbidden_features='#if defined(__ARM_FEATURE_SVE) || defined(__ARM_FEATURE_ATOMICS) || defined(__ARM_FEATURE_SHA3) || defined(__ARM_FEATURE_SHA512)'
	;;
darwin-arm64)
	forbidden_features='#if defined(__ARM_FEATURE_SVE)'
	;;
esac
printf '%s\n' \
	'#if !defined(__OPTIMIZE__)' \
	'#error compiler optimization is disabled' \
	'#endif' \
	"$forbidden_features" \
	'#error compiler enabled instructions above the baseline' \
	'#endif' \
	'int baseline_probe;' |
	compile_probe
if [ "$host_platform" = darwin-arm64 ]; then
	printf '%s\n' \
		'#if !defined(__ARM_NEON) || !defined(__ARM_FEATURE_AES) || !defined(__ARM_FEATURE_SHA2)' \
		'#error Apple M1 baseline is missing required features' \
		'#endif' \
		'int apple_m1_probe;' |
		compile_probe
fi
printf '%s\n' 'CPU baseline checks passed'
