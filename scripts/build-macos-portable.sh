#!/usr/bin/env bash
set -euo pipefail

# Build a portable macOS timg binary: every third-party library is linked
# statically, so the result depends only on macOS system libraries and runs
# on any Mac of the same architecture (macOS 11.0 or newer by default).
#
# The feature set mirrors scripts/build-musl-static.sh, minus PDF rendering
# (poppler needs a static glib stack, which is impractical on macOS) and
# minus the video device input (v4l2 is Linux-only):
#   On:  turbojpeg + libexif, STB, QOI, libdeflate, video decoding (FFmpeg)
#   Off: GraphicsMagick, librsvg, poppler, OpenSlide, libsixel, video device
#
# Dependency versions are pinned to the same ones the musl build uses.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build-macos-portable}"
DEPS_PREFIX="${DEPS_PREFIX:-${ROOT_DIR}/deps-macos-static}"
DEPS_SRC="${DEPS_SRC:-${ROOT_DIR}/deps-macos-src}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

LIBDEFLATE_VERSION="${LIBDEFLATE_VERSION:-1.20}"
LIBJPEG_TURBO_VERSION="${LIBJPEG_TURBO_VERSION:-3.0.3}" # as build-musl-static.sh
LIBEXIF_VERSIONS="0.6.25 0.6.24"                        # as build-musl-static.sh
FFMPEG_VERSION="${FFMPEG_VERSION:-n6.1.1}"              # as build-musl-static.sh

# Build for old macOS, not just the builder's OS version. 11.0 is the oldest
# release that supports arm64, and comfortably covers std::filesystem (10.15+).
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

mkdir -p "${DEPS_SRC}" "${DEPS_PREFIX}"

fetch_tar() { # <url> <destdir>
  mkdir -p "$2"
  curl -fsSL "$1" | tar x -C "$2" --strip-components=1
}

if [ ! -f "${DEPS_PREFIX}/lib/libdeflate.a" ]; then
  echo "=== Building static libdeflate ${LIBDEFLATE_VERSION}"
  fetch_tar "https://github.com/ebiggers/libdeflate/archive/refs/tags/v${LIBDEFLATE_VERSION}.tar.gz" \
    "${DEPS_SRC}/libdeflate"
  cmake -S "${DEPS_SRC}/libdeflate" -B "${DEPS_SRC}/libdeflate/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
    -DLIBDEFLATE_BUILD_GZIP=OFF
  cmake --build "${DEPS_SRC}/libdeflate/build" -j"${JOBS}"
  cmake --install "${DEPS_SRC}/libdeflate/build"
fi

if [ ! -f "${DEPS_PREFIX}/lib/libturbojpeg.a" ]; then
  echo "=== Building static libjpeg-turbo ${LIBJPEG_TURBO_VERSION}"
  fetch_tar "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/${LIBJPEG_TURBO_VERSION}.tar.gz" \
    "${DEPS_SRC}/libjpeg-turbo"
  cmake -S "${DEPS_SRC}/libjpeg-turbo" -B "${DEPS_SRC}/libjpeg-turbo/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${DEPS_PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON
  cmake --build "${DEPS_SRC}/libjpeg-turbo/build" -j"${JOBS}"
  cmake --install "${DEPS_SRC}/libjpeg-turbo/build"
fi

if [ ! -f "${DEPS_PREFIX}/lib/libexif.a" ]; then
  echo "=== Building static libexif"
  LIBEXIF_TARBALL="${DEPS_SRC}/libexif.tar"
  for v in ${LIBEXIF_VERSIONS}; do
    if curl -fsSL -o "${LIBEXIF_TARBALL}" \
      "https://deb.debian.org/debian/pool/main/libe/libexif/libexif_${v}.orig.tar.gz"; then
      break
    fi
  done
  [ -s "${LIBEXIF_TARBALL}" ] || { echo "Failed to download libexif" >&2; exit 2; }
  mkdir -p "${DEPS_SRC}/libexif"
  tar xf "${LIBEXIF_TARBALL}" -C "${DEPS_SRC}/libexif" --strip-components=1
  ( cd "${DEPS_SRC}/libexif" \
    && ./configure --prefix="${DEPS_PREFIX}" \
         --enable-static --disable-shared --disable-nls \
    && make -j"${JOBS}" \
    && make install )
fi

if [ ! -f "${DEPS_PREFIX}/lib/libavformat.a" ]; then
  echo "=== Building static FFmpeg ${FFMPEG_VERSION}"
  rm -rf "${DEPS_SRC}/ffmpeg"
  git clone --depth=1 --branch "${FFMPEG_VERSION}" \
    https://github.com/FFmpeg/FFmpeg.git "${DEPS_SRC}/ffmpeg"
  ( cd "${DEPS_SRC}/ffmpeg" \
    && ./configure \
         --prefix="${DEPS_PREFIX}" \
         --enable-static \
         --disable-shared \
         --disable-programs \
         --disable-doc \
         --disable-debug \
         --disable-network \
         --disable-postproc \
         --disable-avfilter \
         --disable-autodetect \
         --disable-avdevice \
    && make -j"${JOBS}" \
    && make install )
  for lib in libavcodec libavutil libavformat libswscale libswresample; do
    if [ ! -f "${DEPS_PREFIX}/lib/${lib}.a" ]; then
      echo "Missing static FFmpeg library: ${DEPS_PREFIX}/lib/${lib}.a" >&2
      exit 2
    fi
  done
fi

echo "=== Building timg"
rm -rf "${BUILD_DIR}"
# PKG_CONFIG_USE_STATIC_LIBS makes the CMakeLists look up all libraries as
# .a archives via find_library() instead of pkg-config; CMAKE_PREFIX_PATH
# points those lookups at the static prefix built above. The include flag is
# needed because the manual find_library() path does not carry include dirs
# for turbojpeg/libexif headers.
cmake -S "${ROOT_DIR}" -B "${BUILD_DIR}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPKG_CONFIG_USE_STATIC_LIBS=ON \
  -DCMAKE_PREFIX_PATH="${DEPS_PREFIX}" \
  -DCMAKE_CXX_FLAGS="-I${DEPS_PREFIX}/include" \
  -DWITH_OPENSLIDE_SUPPORT=Off \
  -DWITH_GRAPHICSMAGICK=Off \
  -DWITH_RSVG=Off \
  -DWITH_POPPLER=Off \
  -DWITH_LIBSIXEL=Off \
  -DWITH_STB_IMAGE=On \
  -DWITH_QOI_IMAGE=On \
  -DWITH_TURBOJPEG=On \
  -DWITH_VIDEO_DECODING=On \
  -DWITH_VIDEO_DEVICE=Off
cmake --build "${BUILD_DIR}" -j"${JOBS}"

BIN="${BUILD_DIR}/src/timg"
if [ ! -x "${BIN}" ]; then
  echo "Expected binary not found at ${BIN}" >&2
  exit 1
fi

echo
echo "=== Checking portability (only system libraries allowed)"
otool -L "${BIN}"
if otool -L "${BIN}" | tail -n +2 | grep -vE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
  echo "Binary links non-system libraries; it would not be portable." >&2
  exit 1
fi

echo
echo "Feature summary:"
"${BIN}" --version
