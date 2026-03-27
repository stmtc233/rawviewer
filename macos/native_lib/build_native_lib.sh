#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIBRAW_ROOT="${PROJECT_ROOT}/windows/native_lib/libraw"
WRAPPER_SOURCE="${SCRIPT_DIR}/wrapper.cpp"
OUTPUT_DIR="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
OUTPUT_LIB="${OUTPUT_DIR}/libnative_lib.dylib"
BUILD_METADATA="${DERIVED_FILE_DIR}/libnative_lib.metadata"
LEGACY_METADATA="${OUTPUT_LIB}.metadata"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

mkdir -p "${OUTPUT_DIR}"
mkdir -p "$(dirname "${BUILD_METADATA}")"
rm -f "${LEGACY_METADATA}"

if [[ ! -d "${LIBRAW_ROOT}" ]]; then
  echo "LibRaw sources not found at ${LIBRAW_ROOT}" >&2
  exit 1
fi

sources=()
while IFS= read -r -d '' file; do
  sources+=("${file}")
done < <(find "${LIBRAW_ROOT}/src" -name '*.cpp' ! -name '*_ph.cpp' -print0)
sources+=("${WRAPPER_SOURCE}")

tracked_inputs=("${sources[@]}")
tracked_inputs+=("${BASH_SOURCE[0]}")

should_rebuild=0
if [[ ! -f "${OUTPUT_LIB}" ]]; then
  should_rebuild=1
elif [[ ! -f "${BUILD_METADATA}" ]]; then
  should_rebuild=1
elif ! grep -Fxq "ARCHS=${ARCHS}" "${BUILD_METADATA}"; then
  should_rebuild=1
elif ! grep -Fxq "CONFIGURATION=${CONFIGURATION}" "${BUILD_METADATA}"; then
  should_rebuild=1
else
  for source in "${tracked_inputs[@]}"; do
    if [[ "${source}" -nt "${OUTPUT_LIB}" ]]; then
      should_rebuild=1
      break
    fi
  done
fi

if [[ "${should_rebuild}" -eq 0 ]]; then
  exit 0
fi

arch_flags=()
for arch in ${ARCHS}; do
  arch_flags+=("-arch" "${arch}")
done

optimization_flags=("-O3")
if [[ "${CONFIGURATION}" == "Debug" ]]; then
  optimization_flags=("-O0" "-g")
fi

xcrun clang++ \
  "${arch_flags[@]}" \
  -dynamiclib \
  -std=gnu++14 \
  -stdlib=libc++ \
  -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-10.14}" \
  -isysroot "${SDK_PATH}" \
  -I"${LIBRAW_ROOT}" \
  -DLIBRAW_NODLL \
  -fvisibility=hidden \
  "${optimization_flags[@]}" \
  "${sources[@]}" \
  -o "${OUTPUT_LIB}"

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" ]]; then
  sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
  /usr/bin/codesign --force --sign "${sign_identity}" --timestamp=none "${OUTPUT_LIB}"
fi

cat > "${BUILD_METADATA}" <<EOF
ARCHS=${ARCHS}
CONFIGURATION=${CONFIGURATION}
EOF
