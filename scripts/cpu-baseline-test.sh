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
	[ "$CPU_BASELINE_FLAGS" = "-march=$2 -mtune=generic" ]
	[ "$CPU_BASELINE_RUST_CPU" = "$3" ]
	[ "$CFLAGS" = "-O3 $CPU_BASELINE_FLAGS" ]
	[ "$CXXFLAGS" = "-O2 $CPU_BASELINE_FLAGS" ]
	sh -eu -c '[ "$CFLAGS" = "-O3 $CPU_BASELINE_FLAGS" ] && [ "$CXXFLAGS" = "-O2 $CPU_BASELINE_FLAGS" ]'
}

check_baseline linux-x64 x86-64 x86-64
check_baseline linux-arm64 armv8-a generic
check_baseline darwin-arm64 armv8-a generic
unset CFLAGS CXXFLAGS
setup_cpu_baseline linux-x64
[ "$CFLAGS" = "-O2 $CPU_BASELINE_FLAGS" ]
[ "$CXXFLAGS" = "-O2 $CPU_BASELINE_FLAGS" ]
if (setup_cpu_baseline linux-riscv64 >/dev/null 2>&1); then
	printf '%s\n' 'unsupported CPU baseline was accepted' >&2
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
IFS=' ' read -r optimization architecture tuning <<EOF
$CFLAGS
EOF
printf '%s\n' \
	'#if !defined(__OPTIMIZE__)' \
	'#error compiler optimization is disabled' \
	'#endif' \
	'#if defined(__AVX__) || defined(__AVX2__) || defined(__AVX512F__) || defined(__SSE4_2__) || defined(__ARM_FEATURE_SVE) || defined(__ARM_FEATURE_ATOMICS)' \
	'#error compiler enabled instructions above the baseline' \
	'#endif' \
	'int baseline_probe;' |
	"${CC:-cc}" "$optimization" "$architecture" "$tuning" -x c -fsyntax-only -
printf '%s\n' 'CPU baseline checks passed'
