#!/usr/bin/env zsh

# Build dependency-free cjpegli/djpegli binaries with Clang.
#
# All bundled third-party libraries are linked statically. On macOS, the Apple
# system runtime (libSystem/libc++) remains dynamic because the platform does
# not support fully static executables.

emulate -L zsh
set -euo pipefail

typeset -r SOURCE_DIR="${0:A:h}"
typeset -r BUILD_DIR="${BUILD_DIR:-${SOURCE_DIR}/build-static}"
typeset -r OUTPUT_DIR="${OUTPUT_DIR:-${BUILD_DIR}/bin}"

die() {
  print -u2 -- "error: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' command not found"
}

require_command cmake
require_command clang
require_command clang++

typeset -r CC_BIN="${CC:-$(command -v clang)}"
typeset -r CXX_BIN="${CXX:-$(command -v clang++)}"

"${CC_BIN}" --version 2>/dev/null | grep -qi clang || \
  die "CC must point to Clang (current: ${CC_BIN})"
"${CXX_BIN}" --version 2>/dev/null | grep -qi clang || \
  die "CXX must point to Clang (current: ${CXX_BIN})"

# These are the bundled libraries/headers needed by the selected tool build.
typeset -a required_sources=(
  third_party/highway/CMakeLists.txt
  third_party/lcms/CMakeLists.txt
  third_party/libjpeg-turbo/CMakeLists.txt
  third_party/libpng/CMakeLists.txt
  third_party/sjpeg/CMakeLists.txt
  third_party/zlib/CMakeLists.txt
)
typeset source_file
for source_file in "${required_sources[@]}"; do
  [[ -e "${SOURCE_DIR}/${source_file}" ]] || \
    die "missing ${source_file}; run 'git submodule update --init --recursive'"
done

typeset generator
if [[ -n "${CMAKE_GENERATOR:-}" ]]; then
  generator="${CMAKE_GENERATOR}"
elif command -v ninja >/dev/null 2>&1; then
  generator="Ninja"
else
  generator="Unix Makefiles"
fi

typeset jobs="${JOBS:-}"
if [[ -z "${jobs}" ]]; then
  if command -v nproc >/dev/null 2>&1; then
    jobs="$(nproc)"
  else
    jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || print 1)"
  fi
fi
[[ "${jobs}" == <1-> ]] || die "JOBS must be a positive integer"

print -- "Configuring a static Clang build in ${BUILD_DIR}"

cmake \
  -S "${SOURCE_DIR}" \
  -B "${BUILD_DIR}" \
  -G "${generator}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="${CC_BIN}" \
  -DCMAKE_CXX_COMPILER="${CXX_BIN}" \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DJPEGLI_STATIC=ON \
  -DJPEGLI_ENABLE_TOOLS=ON \
  -DJPEGLI_BUNDLE_LIBPNG=ON \
  -DJPEGLI_FORCE_SYSTEM_HWY=OFF \
  -DJPEGLI_FORCE_SYSTEM_LCMS2=OFF \
  -DJPEGLI_ENABLE_SKCMS=OFF \
  -DJPEGLI_ENABLE_SJPEG=ON \
  -DJPEGLI_ENABLE_OPENEXR=OFF \
  -DJPEGLI_ENABLE_TCMALLOC=OFF \
  -DJPEGLI_ENABLE_JPEGLI_LIBJPEG=OFF \
  -DJPEGLI_ENABLE_FUZZERS=OFF \
  -DJPEGLI_ENABLE_DEVTOOLS=OFF \
  -DJPEGLI_ENABLE_BENCHMARK=OFF \
  -DJPEGLI_ENABLE_DOXYGEN=OFF \
  -DJPEGLI_ENABLE_MANPAGES=OFF \
  -DJPEGLI_ENABLE_JNI=OFF \
  -DZLIB_BUILD_SHARED=OFF \
  -DZLIB_BUILD_STATIC=ON \
  -DZLIB_INSTALL=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON \
  -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON

cmake --build "${BUILD_DIR}" \
  --parallel "${jobs}" \
  --target cjpegli djpegli

mkdir -p "${OUTPUT_DIR}"
typeset tool dependency
for tool in cjpegli djpegli; do
  [[ -x "${BUILD_DIR}/tools/${tool}" ]] || \
    die "build completed without tools/${tool}"
  cmake -E copy_if_different \
    "${BUILD_DIR}/tools/${tool}" "${OUTPUT_DIR}/${tool}"
done

# Reject accidental third-party dynamic dependencies. Apple system libraries
# are the unavoidable runtime ABI on macOS; Linux builds must be fully static.
if [[ "$(uname -s)" == Darwin ]]; then
  require_command otool
  for tool in cjpegli djpegli; do
    while IFS= read -r dependency; do
      case "${dependency}" in
        /usr/lib/*|/System/Library/*) ;;
        *) die "${tool} has a non-system dynamic dependency: ${dependency}" ;;
      esac
    done < <(otool -L "${OUTPUT_DIR}/${tool}" | tail -n +2 | awk '{print $1}')
  done
elif command -v readelf >/dev/null 2>&1; then
  for tool in cjpegli djpegli; do
    if readelf -d "${OUTPUT_DIR}/${tool}" 2>/dev/null | grep -q NEEDED; then
      die "${tool} still has dynamic dependencies"
    fi
  done
elif command -v ldd >/dev/null 2>&1; then
  for tool in cjpegli djpegli; do
    if ldd "${OUTPUT_DIR}/${tool}" 2>&1 | \
        grep -Eq '=>|ld-linux|ld-musl|libc[.]so'; then
      die "${tool} still has dynamic dependencies"
    fi
  done
fi

print -- "Built successfully:"
print -- "  ${OUTPUT_DIR}/cjpegli"
print -- "  ${OUTPUT_DIR}/djpegli"
