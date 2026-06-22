#!/bin/bash
# Build LibRetro cores from source for Android and verify 16 KB page alignment.
set -euo pipefail

# ── Sanitize the host build environment ─────────────────────────────────────
# A developer shell often exports CFLAGS/CPPFLAGS/CXXFLAGS/LDFLAGS (and the
# clang-honoured CPATH/LIBRARY_PATH family) pointing at Homebrew's JDK, Ruby and
# Python — e.g. -I/opt/homebrew/opt/openjdk@17/.../include and the matching -L.
# The libretro makefiles append those, so they silently inject host
# (wrong-architecture) headers and libraries into the Android NDK cross-compile.
# Clear them so every core builds only against the NDK sysroot and the flags
# this script passes explicitly. (`unset` of an already-unset name is a no-op,
# even under `set -u`.)
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH OBJCPLUS_INCLUDE_PATH
unset LIBRARY_PATH LD_LIBRARY_PATH
unset PKG_CONFIG_PATH SDKROOT

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_LIBS="$PROJECT_ROOT/android/app/src/main/jniLibs"
BUILD_DIR="$PROJECT_ROOT/build/libretro-cores"
TOOLS_DIR="$PROJECT_ROOT/build/tools"
API_LEVEL=24

path_to_unix() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s\n' "$1"
  fi
}

path_to_cmake() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

find_latest_ndk() {
  local base="$1"
  [ -d "$base" ] || return 1
  find "$base" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -V | tail -1
}

find_executable() {
  local base="$1"
  local candidate
  for candidate in "$base" "$base.exe" "$base.cmd"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

job_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || printf '4\n'
  else
    printf '4\n'
  fi
}

# Major version of the active GNU Make (e.g. 3 or 4), or 0 if undetectable.
# Used to decide whether Make's $(file ...) function is available — it was
# added in GNU Make 4.0, and macOS still ships GNU Make 3.81.
make_major_version() {
  local v
  v="$(make --version 2>/dev/null | sed -n 's/^GNU Make \([0-9][0-9]*\).*/\1/p' | head -1)"
  printf '%s\n' "${v:-0}"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: '$1' is required to build libretro cores from source."
    exit 1
  fi
}

find_nasm() {
  if command -v nasm >/dev/null 2>&1; then
    command -v nasm
    return 0
  fi

  find "$TOOLS_DIR/nasm" -type f \( -name "nasm" -o -name "nasm.exe" \) -print 2>/dev/null | head -1
}

require_cmd git
require_cmd cmake
require_cmd make

JOBS="${JOBS:-$(job_count)}"
FORCE_REBUILD="${FORCE_REBUILD:-0}"
CORE_FILTER="${CORE_FILTER:-}"
BUILT_LIBS=""

NDK=""
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  NDK="$(path_to_unix "$ANDROID_NDK_HOME")"
elif [ -n "${ANDROID_NDK_ROOT:-}" ]; then
  NDK="$(path_to_unix "$ANDROID_NDK_ROOT")"
else
  NDK_BASES=()
  if [ -n "${ANDROID_HOME:-}" ]; then
    NDK_BASES+=("$(path_to_unix "$ANDROID_HOME")/ndk")
  fi
  if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
    NDK_BASES+=("$(path_to_unix "$ANDROID_SDK_ROOT")/ndk")
  fi
  case "$(uname -s)" in
    Darwin*) NDK_BASES+=("$HOME/Library/Android/sdk/ndk") ;;
    Linux*) NDK_BASES+=("$HOME/Android/Sdk/ndk") ;;
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "${LOCALAPPDATA:-}" ]; then
        NDK_BASES+=("$(path_to_unix "$LOCALAPPDATA")/Android/Sdk/ndk")
      fi
      ;;
  esac

  for ndk_base in "${NDK_BASES[@]}"; do
    latest_ndk="$(find_latest_ndk "$ndk_base" || true)"
    if [ -n "$latest_ndk" ]; then
      NDK="$latest_ndk"
    fi
  done
fi

if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  echo "ERROR: No Android NDK found. Set ANDROID_NDK_HOME or ANDROID_HOME."
  exit 1
fi

case "$(uname -s)" in
  Darwin*)
    if [ "$(uname -m)" = "arm64" ] && [ -d "$NDK/toolchains/llvm/prebuilt/darwin-arm64" ]; then
      HOST_TAG="darwin-arm64"
    else
      HOST_TAG="darwin-x86_64"
    fi
    ;;
  Linux*) HOST_TAG="linux-x86_64" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
  *)
    echo "ERROR: Unsupported host OS: $(uname -s)"
    exit 1
    ;;
esac

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TOOLCHAIN" ]; then
  echo "ERROR: Android LLVM toolchain not found: $TOOLCHAIN"
  exit 1
fi

NDK_CMAKE="$(path_to_cmake "$NDK")"
READELF="$(find_executable "$TOOLCHAIN/bin/llvm-readelf")"
LLVM_STRIP="$(find_executable "$TOOLCHAIN/bin/llvm-strip")"

echo "Using NDK: $NDK"
echo "Using host toolchain: $HOST_TAG"
echo "Using jobs: $JOBS"
if [ "$FORCE_REBUILD" = "1" ]; then
  echo "Force rebuild: enabled"
else
  echo "Force rebuild: disabled (existing jniLibs cores will be skipped)"
fi
if [ -n "$CORE_FILTER" ]; then
  echo "Core filter: $CORE_FILTER"
fi

# Bash 3.2 lists
ABIS="${ABIS:-armeabi-v7a arm64-v8a x86_64}"
echo "ABIs: $ABIS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Build started at $(date '+%Y-%m-%d %H:%M:%S')"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Cores: repo_url|core_name|make_target|output_so_name
CORES=(
  "https://github.com/libretro/libretro-fceumm.git|fceumm|fceumm_libretro|libfceumm_libretro_android.so"
  "https://github.com/libretro/snes9x2010.git|snes9x2010|snes9x2010_libretro|libsnes9x2010_libretro_android.so"
  "https://github.com/mgba-emu/mgba.git|mgba|mgba_libretro|libmgba_libretro_android.so"
  "https://github.com/libretro/Genesis-Plus-GX.git|genesis_plus_gx|genesis_plus_gx_libretro|libgenesis_plus_gx_libretro_android.so"
  "https://github.com/libretro/beetle-ngp-libretro.git|mednafen_ngp|mednafen_ngp_libretro|libmednafen_ngp_libretro_android.so"
  "https://github.com/libretro/beetle-wswan-libretro.git|mednafen_wswan|mednafen_wswan_libretro|libmednafen_wswan_libretro_android.so"
  "https://github.com/libretro/beetle-pce-fast-libretro.git|mednafen_pce_fast|mednafen_pce_fast_libretro|libmednafen_pce_fast_libretro_android.so"
  "https://github.com/libretro/beetle-supergrafx-libretro.git|mednafen_supergrafx|mednafen_supergrafx_libretro|libmednafen_supergrafx_libretro_android.so"
  "https://github.com/libretro/mupen64plus-libretro-nx.git|mupen64plus_next|mupen64plus_next_libretro|libmupen64plus_next_gles3_libretro_android.so"
  "https://github.com/libretro/stella2014-libretro.git|stella2014|stella2014_libretro|libstella2014_libretro_android.so"
  "https://github.com/libretro/beetle-vb-libretro.git|mednafen_vb|mednafen_vb_libretro|libmednafen_vb_libretro_android.so"
  "https://github.com/libretro/TIC-80.git|tic80|tic80_libretro|libtic80_libretro_android.so"
  "https://github.com/jtothebell/fake-08.git|fake08|fake08_libretro|libfake08_libretro_android.so"
  # melonDS — Nintendo DS, GPLv3, HLE via FreeBIOS for DS mode.
  "https://github.com/libretro/melonDS.git|melonds|melonds_libretro|libmelonds_libretro_android.so"
  # Beetle PSX HW — PlayStation 1, GPLv2, RA-supported. Bundled OpenBIOS
  # (downloaded separately) provides free fallback when user has no Sony BIOS.
  "https://github.com/libretro/beetle-psx-libretro.git|mednafen_psx_hw|mednafen_psx_hw_libretro|libmednafen_psx_hw_libretro_android.so"
  # FreeIntv — Mattel Intellivision, GPLv3. BIOS (exec.bin + grom.bin) required.
  "https://github.com/libretro/FreeIntv.git|freeintv|freeintv_libretro|libfreeintv_libretro_android.so"
)

mkdir -p "$BUILD_DIR"
for abi in $ABIS; do
  mkdir -p "$JNI_LIBS/$abi"
done

copy_cpp_runtime() {
  local abi toolchain_arch copied=0

  echo ""
  echo "═══ Copying libc++ Runtime ═══"
  echo "  [$(date '+%H:%M:%S')] Starting C++ runtime deployment..."

  for abi in $ABIS; do
    toolchain_arch="$(runtime_toolchain_arch "$abi")"
    copy_runtime_for_abi "$abi" "$toolchain_arch" && copied=1
  done

  if [ "$copied" -eq 0 ]; then
    echo "  ✓ libc++_shared.so already present for selected ABIs"
  fi
  echo "  [$(date '+%H:%M:%S')] ✓ C++ runtime ready"
}

runtime_toolchain_arch() {
  case "$1" in
    armeabi-v7a) printf '%s\n' "arm-linux-androideabi" ;;
    arm64-v8a) printf '%s\n' "aarch64-linux-android" ;;
    x86_64) printf '%s\n' "x86_64-linux-android" ;;
    *)
      echo "ERROR: Unsupported ABI for libc++ runtime: $1" >&2
      return 1
      ;;
  esac
}

copy_runtime_for_abi() {
  local abi="$1" toolchain_arch="$2"
  local source_so="$TOOLCHAIN/sysroot/usr/lib/$toolchain_arch/libc++_shared.so"
  local target_so="$JNI_LIBS/$abi/libc++_shared.so"

  if [ "$FORCE_REBUILD" != "1" ] && [ -f "$target_so" ]; then
    echo "  ↷ Skipping libc++_shared.so for $abi; already exists"
    return 1
  fi

  cp "$source_so" "$target_so"
  echo "  ✓ copied libc++_shared.so ($abi)"
  return 0
}

clone_or_pull() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "  [$(date '+%H:%M:%S')] Updating existing repository..."
    git -C "$dir" pull --ff-only 2>/dev/null || true
    echo "  [$(date '+%H:%M:%S')] Updating submodules..."
    git -C "$dir" submodule update --init --recursive --depth 1 2>/dev/null || true
    echo "  [$(date '+%H:%M:%S')] Repository up to date"
  else
    echo "  [$(date '+%H:%M:%S')] Cloning from $url (this may take a minute)..."
    git clone --depth 1 --recurse-submodules --shallow-submodules "$url" "$dir" 2>&1 | tail -2
    echo "  [$(date '+%H:%M:%S')] Clone complete"
  fi
}

core_output_path() {
  local abi="$1" output_so="$2"
  printf '%s\n' "$JNI_LIBS/$abi/$output_so"
}

should_build_core_abi() {
  local core_name="$1" output_so="$2" abi="$3"
  local target_so
  target_so="$(core_output_path "$abi" "$output_so")"

  if [ "$FORCE_REBUILD" != "1" ] && [ -f "$target_so" ]; then
    echo "  ↷ Skipping $core_name for $abi; $target_so already exists"
    return 1
  fi

  return 0
}

core_needs_build() {
  local core_name="$1" output_so="$2" abi
  for abi in $ABIS; do
    if should_build_core_abi "$core_name" "$output_so" "$abi" >/dev/null; then
      return 0
    fi
  done
  return 1
}

core_is_selected() {
  local core_name="$1" output_so="$2" selected

  [ -z "$CORE_FILTER" ] && return 0
  for selected in $CORE_FILTER; do
    if [ "$selected" = "$core_name" ] || [ "$selected" = "$output_so" ]; then
      return 0
    fi
  done

  return 1
}

record_built_lib() {
  local abi="$1" output_so="$2"
  BUILT_LIBS="$BUILT_LIBS $abi/$output_so"
}

copy_core_to_jni() {
  local built_so="$1" output_so="$2" abi="$3"
  local target_so="$JNI_LIBS/$abi/$output_so"

  mkdir -p "$JNI_LIBS/$abi"
  cp "$built_so" "$target_so"
  record_built_lib "$abi" "$output_so"
  echo "  ✓ Copied to $target_so"
}

build_mgba_cmake() {
  local src_dir="$1" output_so="$2" abi="$3"
  local cmake_build="$src_dir/build_$abi"
  mkdir -p "$cmake_build"

  echo "  [$(date '+%H:%M:%S')] Configuring mGBA with CMake..."
  cmake -S "$src_dir" -B "$cmake_build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_CMAKE/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DANDROID_LD=lld \
    -DCMAKE_C_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DCMAKE_CXX_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF \
    -DUSE_EPOXY=OFF -DUSE_SQLITE3=OFF -DUSE_PNG=OFF -DUSE_ZLIB=ON -DM_CORE_GBA=ON -DM_CORE_GB=ON >/dev/null 2>&1

  echo "  [$(date '+%H:%M:%S')] Building mGBA (using $JOBS jobs)..."
  cmake --build "$cmake_build" --config Release -j"$JOBS" >/dev/null 2>&1

  local built_so=$(find "$cmake_build" -name "*mgba*libretro*.so" -o -name "mgba_libretro.so" | head -1)
  if [ -n "$built_so" ]; then
    copy_core_to_jni "$built_so" "$output_so" "$abi"
  else
    echo "  ✗ mGBA cmake build produced no .so file!"
    return 1
  fi
}

# TIC-80 — MIT licensed fantasy console. Builds via CMake from the `core/`
# subdirectory; passes 16 KB page-size linker flags for Google Play compliance.
build_tic80_cmake() {
  local src_dir="$1" output_so="$2" abi="$3"
  local cmake_build="$src_dir/build_$abi"
  mkdir -p "$cmake_build"

  # CORE_ARGS aligned with libretro's GitLab CI for TIC-80, with the few
  # languages disabled that don't cross-compile cleanly on Android NDK.
  cmake -S "$src_dir/core" -B "$cmake_build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_CMAKE/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DANDROID_LD=lld \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DCMAKE_CXX_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DBUILD_LIBRETRO=ON -D__LIBRETRO__=ON \
    -DBUILD_PLAYER=OFF -DBUILD_PRO=OFF -DBUILD_SDL=OFF -DBUILD_TOOLS=OFF \
    -DBUILD_TOUCH_INPUT=OFF -DBUILD_STATIC=ON -DBUILD_WITH_ALL=OFF \
    -DBUILD_WITH_LUA=ON -DBUILD_WITH_MOON=ON -DBUILD_WITH_FENNEL=ON \
    -DBUILD_WITH_WREN=ON -DBUILD_WITH_SQUIRREL=ON -DBUILD_WITH_JS=ON \
    -DBUILD_WITH_WASM=ON \
    -DBUILD_WITH_PYTHON=OFF -DBUILD_WITH_RUBY=OFF -DBUILD_WITH_YUE=OFF \
    -DBUILD_WITH_SCHEME=OFF -DBUILD_WITH_JANET=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_Doxygen=ON -DBUILD_EDITORS=OFF 2>&1 | tail -5

  cmake --build "$cmake_build" --config Release --target tic80_libretro \
    -j"$JOBS" 2>&1 | tail -10

  local built_so=$(find "$cmake_build" -name "tic80_libretro_android.so" | head -1)
  if [ -n "$built_so" ]; then
    copy_core_to_jni "$built_so" "$output_so" "$abi"
  else
    echo "  ✗ TIC-80 cmake build produced no .so file!"
    return 1
  fi
}

# FAKE-08 — MIT licensed PICO-8 player (libretro core). Uses ndk-build via the
# upstream `platform/libretro/jni/` makefile. We override APP_ABI per-build,
# add 16 KB page-size linker flags via APP_LDFLAGS, and add x86_64 support.
build_fake08_ndk() {
  local src_dir="$1" output_so="$2" abi="$3"
  local jni_dir="$src_dir/platform/libretro/jni"
  local ndk_build
  ndk_build="$(find_executable "$NDK/ndk-build" || true)"

  if [ -z "$ndk_build" ]; then
    echo "  ✗ ndk-build not found in $NDK"
    return 1
  fi

  # Run a clean per-ABI build to avoid cross-ABI artifact pollution.
  rm -rf "$src_dir/platform/libretro/obj" "$src_dir/platform/libretro/libs"

  (cd "$jni_dir" && "$ndk_build" \
      APP_ABI="$abi" \
      APP_PLATFORM="android-$API_LEVEL" \
      APP_SHORT_COMMANDS=true \
      APP_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
      NDK_PROJECT_PATH=".." \
      NDK_APPLICATION_MK="Application.mk" \
      -j"$JOBS") 2>&1 | tail -15

  local built_so="$src_dir/platform/libretro/libs/$abi/libfake08.so"
  if [ -f "$built_so" ]; then
    copy_core_to_jni "$built_so" "$output_so" "$abi"
  else
    echo "  ✗ FAKE-08 ndk-build produced no .so file at $built_so"
    return 1
  fi
}

build_android_jni() {
  local src_dir="$1" output_so="$2" abi="$3"
  local jni_dir="$src_dir/jni"
  local ndk_build
  local ndk_jobs="$JOBS"
  ndk_build="$(find_executable "$NDK/ndk-build" || true)"

  if [ -z "$ndk_build" ]; then
    echo "  ✗ ndk-build not found in $NDK"
    return 1
  fi
  if [ ! -f "$jni_dir/Android.mk" ]; then
    echo "  ✗ Android.mk not found at $jni_dir"
    return 1
  fi

  rm -rf "$src_dir/obj" "$src_dir/libs"

  # NDK r29's bundled GNU make prints repeated "fcntl(): Bad file descriptor"
  # jobserver noise for melonDS parallel ndk-builds on macOS. The build is
  # correct either way, but serializing this core keeps warning logs actionable.
  # Set MELONDS_NDK_JOBS to opt back into parallelism for local speed runs.
  if [ "$output_so" = "libmelonds_libretro_android.so" ]; then
    ndk_jobs="${MELONDS_NDK_JOBS:-1}"
    echo "  [$(date '+%H:%M:%S')] melonDS A32JIT_PROFILE=${A32JIT_PROFILE:-0}"
  fi

  if [ "$ndk_jobs" != "$JOBS" ]; then
    echo "  [$(date '+%H:%M:%S')] Using ndk-build jobs=$ndk_jobs for quiet $output_so build"
  fi

  (cd "$jni_dir" && "$ndk_build" \
      APP_ABI="$abi" \
      APP_PLATFORM="android-$API_LEVEL" \
      APP_SHORT_COMMANDS=true \
      APP_LDFLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
      NDK_PROJECT_PATH=".." \
      NDK_APPLICATION_MK="Application.mk" \
      A32JIT_PROFILE="${A32JIT_PROFILE:-0}" \
      -j"$ndk_jobs") 2>&1 | tail -20

  local built_so="$src_dir/libs/$abi/libretro.so"
  if [ -f "$built_so" ]; then
    copy_core_to_jni "$built_so" "$output_so" "$abi"
  else
    echo "  ✗ ndk-build produced no .so file at $built_so"
    return 1
  fi
}

patch_fceumm_core_options_overflow() {
  local build_dir="$1"
  echo "  Patching FCEUmm core options overflow..."

  # Upstream currently declares MAX_CORE_OPTIONS as 42, but the common option
  # table already has 43 entries before the sentinel ("fceumm_ramstate" is the
  # 43rd), and this same array is also meant to receive up to 8 VS dipswitch
  # options. set_variables() copies the table into option_defs_us before asking
  # the frontend which core-options API it supports; with the 42-entry array,
  # that 43rd copy lands on the adjacent environ_cb pointer and the next
  # environ call jumps into .rodata. Patch only the copied build tree.
  local options_h
  options_h="$(find "$build_dir" -name libretro_core_options.h -print 2>/dev/null | head -1)"
  if [ -n "$options_h" ]; then
    perl -0pi -e 's/#define MAX_CORE_OPTIONS[[:space:]]+42/#define MAX_CORE_OPTIONS 64/' "$options_h"
    if grep -q "#define MAX_CORE_OPTIONS 64" "$options_h"; then
      echo "    ✓ libretro_core_options.h: MAX_CORE_OPTIONS raised to 64"
    else
      echo "    ✗ libretro_core_options.h: MAX_CORE_OPTIONS patch did not match"
      return 1
    fi
  fi

  # Clang warns about the literal "src/input/*.c" inside this block comment
  # because "/*" looks like a nested comment opener. Keep the source meaning but
  # avoid the token sequence that trips -Wcomment.
  local input_h="$build_dir/src/input.h"
  if [ -f "$input_h" ]; then
    perl -0pi -e 's|Defined in src/input/\*\.c, called from|Defined in src/input source files, called from|' "$input_h"
    if ! grep -q 'Defined in src/input/\*\.c, called from' "$input_h"; then
      echo "    ✓ input.h: nested comment marker removed"
    else
      echo "    ✗ input.h: warning patch did not match"
      return 1
    fi
  fi
}

patch_mupen64plus_makefile() {
  local makefile="$1"
  [ -f "$makefile" ] || return 0

  awk '
    $0 == "\t$(CXX) -o $@ $(OBJECTS) $(LDFLAGS) $(GL_LIB)" {
      print "\t$(file >$@.rsp,$(OBJECTS) $(LDFLAGS) $(GL_LIB))"
      print "\t$(CXX) -o $@ @$@.rsp"
      next
    }
    { print }
  ' "$makefile" > "$makefile.tmp"
  mv "$makefile.tmp" "$makefile"
}

# Patch melonDS libretro source for GLES3 / Android OpenGL compilation.
# The upstream source targets desktop OpenGL Core 3.1; these patches make it
# compatible with GLES3 on Android via glsm:
#   1. Makefile.common: swap glsym_gl.c → glsym_es3.c (GLES3 symbol loader)
#   2. Android.mk: set HAVE_OPENGL := 1 and link -lGLESv3 -lEGL
#   3. opengl.cpp: replace glMapBuffer (not in GLES3) / drop glBindFragDataLocation /
#      fix integer texture format incompatible with sampler2D in GLES3
#   4. shaders.h: upgrade from GLSL #version 140 → #version 300 es
patch_melonds_for_gles3() {
  local build_dir="$1"
  echo "  Patching melonDS source for GLES3 / Android OpenGL..."

  # ── 1. Makefile.common: GLES3 symbol loader ───────────────────────────────
  local makefile_common="$build_dir/Makefile.common"
  if [ -f "$makefile_common" ]; then
    # glsym_gl.c is the desktop GL symbol loader; glsym_es3.c is for GLES3.
    sed -i '' 's|libretro-common/glsym/glsym_gl\.c|libretro-common/glsym/glsym_es3.c|g' \
      "$makefile_common"
    echo "    ✓ Makefile.common: glsym_gl → glsym_es3"
  fi

  # ── 1b. rglgen_headers.h: swap desktop GL header for GLES3 ────────────────
  # rglgen_headers.h unconditionally includes <GL/gl.h> (desktop OpenGL),
  # which does not exist in the Android NDK sysroot.  On Android we target
  # GLES3, so replace it with the GLES3 header.
  local rglgen_headers="$build_dir/src/libretro/libretro-common/include/glsym/rglgen_headers.h"
  if [ -f "$rglgen_headers" ]; then
    sed -i '' 's|#include <GL/gl\.h>|#include <GLES3/gl3.h>|g' "$rglgen_headers"
    # Also guard the glext include the same way so it uses the GLES extension header.
    sed -i '' 's|#include <GL/glext\.h>|#include <GLES3/gl3ext.h>|g' "$rglgen_headers"
    echo "    ✓ rglgen_headers.h: GL/gl.h → GLES3/gl3.h"
  fi

  # ── 1c. glsmsym.h + glsm.c: replace desktop-only types missing from GLES3 ─
  # GLclampd and GLdouble are desktop GL types not defined in GLES3 headers.
  # GLclampd maps to GLclampf (GLES3 uses float for depth range).
  # GLdouble maps to double (plain C type, always available).
  # Both glsmsym.h (included state inline wrappers) and glsm.c (rgl* function
  # signatures themselves) use these types, so both must be patched.
  local glsmsym_h="$build_dir/src/libretro/libretro-common/include/glsm/glsmsym.h"
  if [ -f "$glsmsym_h" ]; then
    sed -i '' 's/GLclampd/GLclampf/g' "$glsmsym_h"
    sed -i '' 's/GLdouble/double/g'   "$glsmsym_h"
    echo "    ✓ glsmsym.h: GLclampd → GLclampf, GLdouble → double"
  fi
  local glsm_c="$build_dir/src/libretro/libretro-common/glsm/glsm.c"
  if [ -f "$glsm_c" ]; then
    sed -i '' 's/GLclampd/GLclampf/g' "$glsm_c"
    sed -i '' 's/GLdouble/double/g'   "$glsm_c"
    echo "    ✓ glsm.c: GLclampd → GLclampf, GLdouble → double"
  fi

  # ── 2. Android.mk: enable OpenGL and link GLES3 + EGL ─────────────────────
  local android_mk="$build_dir/jni/Android.mk"
  if [ -f "$android_mk" ]; then
    # Create a force-included GLES3 compatibility shim that stubs desktop-only
    # GL functions referenced inside #if defined(HAVE_OPENGL) blocks in
    # libretro-common's glsm.c.  These functions don't exist in GLES3.0/3.1;
    # the stubs let the code compile while preserving correct GLES3 behaviour.
    local compat_h="$build_dir/jni/gles3_compat.h"
    cat > "$compat_h" << 'COMPAT_EOF'
/* GLES3 compatibility shims — force-included by build_libretro_cores.sh.
 * Stubs desktop-only OpenGL functions that glsm.c calls inside
 * #if defined(HAVE_OPENGL) blocks but which are absent from GLES3.0/3.1. */
#pragma once

/* ── Draw buffer selection ─────────────────────────────────────────────────
 * glDrawBuffer: not in GLES3 — back buffer is always the sole draw target. */
#ifndef glDrawBuffer
#  define glDrawBuffer(buf) ((void)(buf))
#endif

/* ── Base-vertex draw calls (GLES3.2+ / GL_EXT_draw_elements_base_vertex) ──
 * Fall back to standard draw calls (basevertex ignored). */
#ifndef glDrawElementsBaseVertex
#  define glDrawElementsBaseVertex(mode,count,type,indices,bv) \
     glDrawElements(mode, count, type, indices)
#endif
#ifndef glDrawRangeElementsBaseVertex
#  define glDrawRangeElementsBaseVertex(mode,st,en,cnt,type,idx,bv) \
     glDrawRangeElements(mode, st, en, cnt, type, idx)
#endif
#ifndef glDrawElementsInstancedBaseVertex
#  define glDrawElementsInstancedBaseVertex(mode,cnt,type,idx,ic,bv) \
     glDrawElementsInstanced(mode, cnt, type, idx, ic)
#endif
#ifndef glMultiDrawElementsBaseVertex
#  define glMultiDrawElementsBaseVertex(mode,cnt,type,idx,dc,bv) ((void)0)
#endif

/* ── Multi-draw (not in GLES3 core; EXT extension only) ───────────────────*/
#ifndef glMultiDrawArrays
#  define glMultiDrawArrays(mode,first,count,dc)   ((void)0)
#endif
#ifndef glMultiDrawElements
#  define glMultiDrawElements(mode,count,type,idx,dc) ((void)0)
#endif

/* ── Base-instance draw calls (GL 4.2, not in GLES3) ─────────────────────*/
#ifndef glDrawArraysInstancedBaseInstance
#  define glDrawArraysInstancedBaseInstance(m,f,c,ic,bi) \
     glDrawArraysInstanced(m, f, c, ic)
#endif
#ifndef glDrawElementsInstancedBaseInstance
#  define glDrawElementsInstancedBaseInstance(m,c,t,i,ic,bi) \
     glDrawElementsInstanced(m, c, t, i, ic)
#endif
#ifndef glDrawElementsInstancedBaseVertexBaseInstance
#  define glDrawElementsInstancedBaseVertexBaseInstance(m,c,t,i,ic,bv,bi) \
     glDrawElementsInstanced(m, c, t, i, ic)
#endif

/* ── Transform-feedback draw calls (GL 4.x, not in GLES3) ────────────────*/
#ifndef glDrawTransformFeedback
#  define glDrawTransformFeedback(mode,id)          ((void)0)
#endif
#ifndef glDrawTransformFeedbackInstanced
#  define glDrawTransformFeedbackInstanced(m,id,ic) ((void)0)
#endif
#ifndef glDrawTransformFeedbackStream
#  define glDrawTransformFeedbackStream(m,id,s)     ((void)0)
#endif
#ifndef glDrawTransformFeedbackStreamInstanced
#  define glDrawTransformFeedbackStreamInstanced(m,id,s,ic) ((void)0)
#endif

/* ── Texture / framebuffer (GLES3.2 only) ─────────────────────────────────*/
#ifndef glTextureView
#  define glTextureView(tex,tgt,otex,fmt,ml,nl,mla,nla) ((void)0)
#endif
#ifndef glFramebufferTexture
#  define glFramebufferTexture(tgt,att,tex,lvl) \
     glFramebufferTexture2D(tgt, att, GL_TEXTURE_2D, tex, lvl)
#endif
#ifndef glTexImage2DMultisample
#  define glTexImage2DMultisample(tgt,samp,fmt,w,h,fx) ((void)0)
#endif
#ifndef glTexBuffer
#  define glTexBuffer(tgt,fmt,buf) ((void)0)
#endif

/* ── Polygon / rasteriser state (desktop only) ────────────────────────────*/
#ifndef glPolygonMode
#  define glPolygonMode(face, mode) ((void)(face),(void)(mode))
#endif
#ifndef glProvokingVertex
#  define glProvokingVertex(mode) ((void)(mode))
#endif

/* ── Per-draw-buffer blend (GLES3.2 only) ─────────────────────────────────*/
#ifndef glBlendEquationi
#  define glBlendEquationi(buf,mode)       glBlendEquation(mode)
#endif
#ifndef glBlendEquationSeparatei
#  define glBlendEquationSeparatei(buf,rgb,a) glBlendEquationSeparate(rgb,a)
#endif
#ifndef glBlendFunci
#  define glBlendFunci(buf,sfac,dfac)      glBlendFunc(sfac,dfac)
#endif
#ifndef glBlendFuncSeparatei
#  define glBlendFuncSeparatei(buf,sr,dr,sa,da) glBlendFuncSeparate(sr,dr,sa,da)
#endif
/* CRITICAL: per-draw-buffer color mask shim.
 *
 * melonDS's GPU3D_OpenGL.cpp uses MRT (color attachment 0 = RGBA color,
 * attachment 1 = polygon-attribute buffer) and issues PAIRS of
 * glColorMaski calls — one per attachment — to enable/disable writes
 * independently.  Naive shim
 *
 *     #define glColorMaski(idx, r, g, b, a) glColorMask(r, g, b, a)
 *
 * makes the SECOND call (for attachment 1) clobber the global mask the
 * first call (for attachment 0) just set.  That's a per-frame state
 * corruption — the global mask ends up reflecting attachment 1's intent
 * (often partially-FALSE), so writes to attachment 0 (the color buffer
 * we actually present) are silently masked off or partially dropped.
 *
 * GLES3.0/3.1 has no real per-attachment color masking — that's GLES3.2 /
 * GL_EXT_draw_buffers_indexed.  But melonDS's intent is "write to
 * attachment 0 fully; restrict attachment 1 partially" — so honouring
 * ONLY the idx==0 call gives correct attachment 0 behaviour and just
 * loses the (less important) attachment 1 masking, which manifests as
 * extra writes to the AttrBuffer post-process layer.  Acceptable.
 */
#ifndef glColorMaski
#  define glColorMaski(idx,r,g,b,a)  do { if ((idx) == 0) glColorMask(r,g,b,a); } while (0)
#endif
#ifndef glEnablei
#  define glEnablei(cap,idx)               glEnable(cap)
#endif
#ifndef glDisablei
#  define glDisablei(cap,idx)              glDisable(cap)
#endif

/* ── Timer queries (desktop GL 3.3 / EXT on GLES) ────────────────────────*/
#ifndef glQueryCounter
#  define glQueryCounter(id,tgt)           ((void)0)
#endif
#ifndef glGetQueryObjecti64v
#  define glGetQueryObjecti64v(id,pn,par)  ((void)0)
#endif
#ifndef glGetQueryObjectui64v
#  define glGetQueryObjectui64v(id,pn,par) ((void)0)
#endif

/* ── Immutable buffer storage (GL 4.4 / GL_EXT_buffer_storage) ───────────
 * Fall back to glBufferData with DYNAMIC_DRAW usage. */
#ifndef glBufferStorage
#  define glBufferStorage(tgt,sz,data,flags) \
     glBufferData(tgt, sz, data, GL_DYNAMIC_DRAW)
#endif

/* ── Buffer-clearing utilities (GL 4.3, not in GLES3) ────────────────────*/
#ifndef glClearBufferData
#  define glClearBufferData(tgt,ifmt,fmt,type,data) ((void)0)
#endif
#ifndef glClearBufferSubData
#  define glClearBufferSubData(tgt,ifmt,ofs,sz,fmt,t,d) ((void)0)
#endif
#ifndef glInvalidateBufferData
#  define glInvalidateBufferData(buf) ((void)0)
#endif
#ifndef glInvalidateBufferSubData
#  define glInvalidateBufferSubData(buf,ofs,len) ((void)0)
#endif

/* ── Compute (GLES3.1, not GLES3.0) ──────────────────────────────────────*/
#ifndef glDispatchCompute
#  define glDispatchCompute(x,y,z) ((void)0)
#endif
#ifndef glMemoryBarrier
#  define glMemoryBarrier(bits) ((void)0)
#endif
#ifndef glBindImageTexture
#  define glBindImageTexture(u,t,lvl,lyr,layer,ac,fmt) ((void)0)
#endif

/* ── Clip control (GL 4.5, not in GLES3) ────────────────────────────────*/
#ifndef glClipControl
#  define glClipControl(origin, depth) ((void)0)
#endif

/* ── Buffer readback (not in GLES3 core; use glMapBufferRange instead) ────*/
#ifndef glGetBufferSubData
#  define glGetBufferSubData(tgt,ofs,sz,data) ((void)0)
#endif

/* ── Direct-state-access helpers (GL 4.5, not in GLES3) ─────────────────*/
#ifndef glNamedFramebufferDrawBuffer
#  define glNamedFramebufferDrawBuffer(fb,buf) glDrawBuffer(buf)
#endif
#ifndef glNamedFramebufferReadBuffer
#  define glNamedFramebufferReadBuffer(fb,src) glReadBuffer(src)
#endif

/* ── Fragment output location binding (desktop GL 3.0) ───────────────────
 * glBindFragDataLocation is absent from GLES3; layout(location=N) in the
 * shader handles output slot assignment instead. */
#ifndef glBindFragDataLocation
#  define glBindFragDataLocation(prog,colNum,name) ((void)0)
#endif

/* ── Double-precision vertex attributes (GL 4.1, not in GLES3) ───────────
 * Fall back to the float variant; precision may differ but it compiles. */
#ifndef glVertexAttribLPointer
#  define glVertexAttribLPointer(idx,sz,type,stride,ptr) \
     glVertexAttribPointer(idx, sz, GL_FLOAT, GL_FALSE, stride, ptr)
#endif

/* ── Image copy (GLES3.2+ / GL_EXT_copy_image) ────────────────────────────
 * glCopyImageSubData is guarded by HAVE_OPENGL which we set; stub it out on
 * GLES3.0/3.1 where the function is not available. */
#ifndef glCopyImageSubData
#  define glCopyImageSubData(sn,st,sl,sx,sy,sz,dn,dt,dl,dx,dy,dz,w,h,d) \
     ((void)0)
#endif

/* ── Sample shading (GLES3.2 only) ───────────────────────────────────────*/
#ifndef glMinSampleShading
#  define glMinSampleShading(v) ((void)(v))
#endif

/* ── Enum values not defined in GLES3 headers ────────────────────────────*/
#ifndef GL_WRITE_ONLY
#  define GL_WRITE_ONLY 0x88B9
#endif
#ifndef GL_READ_ONLY
#  define GL_READ_ONLY  0x88B8
#endif
#ifndef GL_LINES_ADJACENCY
#  define GL_LINES_ADJACENCY 0x000A
#endif
#ifndef GL_LINE_STRIP_ADJACENCY
#  define GL_LINE_STRIP_ADJACENCY 0x000B
#endif
#ifndef GL_TRIANGLES_ADJACENCY
#  define GL_TRIANGLES_ADJACENCY 0x000C
#endif
#ifndef GL_TRIANGLE_STRIP_ADJACENCY
#  define GL_TRIANGLE_STRIP_ADJACENCY 0x000D
#endif
COMPAT_EOF

    # Insert HAVE_OPENGL := 1 directly after the HAVE_THREADS line so that
    # Makefile.common's ifeq ($(HAVE_OPENGL), 1) block fires.
    awk '/^HAVE_THREADS/{print; print "HAVE_OPENGL := 1"; next} {print}' "$android_mk" > "$android_mk.tmp" && mv "$android_mk.tmp" "$android_mk"
    # Define HAVE_OPENGLES3 and HAVE_OPENGLES so that glsm.h (libretro-common)
    # includes glsym_es3.h instead of the desktop glsym_gl.h.
    # Force-include the compat shim via $(LOCAL_PATH) — ndk-build expands this
    # to the Windows-native jni/ path, which clang.exe can locate at build time.
    awk '/include \$\(BUILD_SHARED_LIBRARY\)/{
      print "LOCAL_CFLAGS += -DHAVE_OPENGLES3 -DHAVE_OPENGLES -include $(LOCAL_PATH)/gles3_compat.h"
      print "LOCAL_LDLIBS += -lGLESv3 -lEGL -llog"
      print "include $(BUILD_SHARED_LIBRARY)"
      next
    } {print}' "$android_mk" > "$android_mk.tmp" && mv "$android_mk.tmp" "$android_mk"
    echo "    ✓ Android.mk: HAVE_OPENGL=1, -DHAVE_OPENGLES3, gles3_compat.h, -lGLESv3 -lEGL -llog"
  fi

  # ── 3. opengl.cpp: GLES3 compatibility ────────────────────────────────────
  local opengl_cpp="$build_dir/src/libretro/opengl.cpp"
  if [ -f "$opengl_cpp" ]; then
    # glBindFragDataLocation does not exist in GLES3; output location is
    # specified via layout(location=0) in the fragment shader instead.
    sed -i '' '/glBindFragDataLocation/d' "$opengl_cpp"

    # glMapBuffer is not available in GLES3; replace with glMapBufferRange.
    # There are two call sites (setup_opengl_frame_state + render_opengl_frame).
    sed -i '' \
      's/glMapBuffer(GL_UNIFORM_BUFFER, GL_WRITE_ONLY)/glMapBufferRange(GL_UNIFORM_BUFFER, 0, sizeof(GL_ShaderConfig), GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT)/g' \
      "$opengl_cpp"

    # GL_RGBA8UI / GL_RGBA_INTEGER is an integer texture format.  In GLES3 an
    # integer texture *must* be sampled with a usampler2D, but the shader
    # declares sampler2D.  Change to a normalised GL_RGBA8 / GL_RGBA format so
    # the sampler2D declaration is correct and glTexSubImage2D works normally.
    sed -i '' 's/GL_RGBA8UI/GL_RGBA8/g'       "$opengl_cpp"
    sed -i '' 's/GL_RGBA_INTEGER/GL_RGBA/g'   "$opengl_cpp"

    echo "    ✓ opengl.cpp: glMapBufferRange, GL_RGBA8, removed glBindFragDataLocation"
  fi

  # ── 3b. GPU3D_OpenGL.cpp: GLES3 compatibility ─────────────────────────────
  # GPU3D_OpenGL.cpp uses several desktop-only GL identifiers that don't exist
  # in GLES3: GL_UNSIGNED_SHORT_1_5_5_5_REV, GL_BGRA, GL_READ_ONLY, glMapBuffer.
  local gpu3d_cpp="$build_dir/src/GPU3D_OpenGL.cpp"
  if [ -f "$gpu3d_cpp" ]; then
    # Prepend compat defines for missing GLES3 constants.
    printf '// GLES3 compat shims (injected by build_libretro_cores.sh)\n#ifndef GL_UNSIGNED_SHORT_1_5_5_5_REV\n#define GL_UNSIGNED_SHORT_1_5_5_5_REV GL_UNSIGNED_SHORT_5_5_5_1\n#endif\n#ifndef GL_BGRA\n#define GL_BGRA GL_RGBA\n#endif\n\n' \
      | cat - "$gpu3d_cpp" > "$gpu3d_cpp.tmp" && mv "$gpu3d_cpp.tmp" "$gpu3d_cpp"
    # glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY) → glMapBufferRange.
    # The readback buffer holds 256×192 RGBA pixels = 196608 bytes.
    sed -i '' \
      's/glMapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY)/glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, 256*192*4, GL_MAP_READ_BIT)/g' \
      "$gpu3d_cpp"

    # The UBO for 3D shaders is ShaderConfig (128 bytes). Mapping 65536 bytes
    # on a 128-byte buffer causes GL_INVALID_VALUE on strict GLES3 drivers.
    sed -i '' \
      's/glMapBuffer(GL_UNIFORM_BUFFER, GL_WRITE_ONLY)/glMapBufferRange(GL_UNIFORM_BUFFER, 0, sizeof(ShaderConfig), GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT)/g' \
      "$gpu3d_cpp"

    # ── NDS palette VRAM bit-layout swizzle (NEW 2026-05-28) ──────────────
    # The TexPalette uploads use `GL_UNSIGNED_SHORT_1_5_5_5_REV` — NDS native
    # layout (A in MSB, R in LSB).  Our GLES3 shim maps this to
    # `GL_UNSIGNED_SHORT_5_5_5_1` (R in MSB, A in LSB), so the bit positions
    # all SHIFT by one component — each pixel's R gets bits that originally
    # belonged to B, G gets bits originally in R, etc.  Result: every
    # textured 3D polygon's palette lookup returns scrambled colours (user
    # report: "greenish greyish, not normal").
    #
    # Fix: swizzle the upload bytes from 1_5_5_5_REV (NDS) to 5_5_5_1 in
    # CPU before the upload.  Static buffer is shared across all 6 iterations
    # of the palette upload loop; melonDS is single-threaded for GL.
    #
    # Write the replacement to a temp file so we don't fight shell-quoting.
    cat > /tmp/yage_swizzle_replacement.txt <<'REPL_EOF'
{ /* YAGE: NDS palette 1_5_5_5_REV -> 5_5_5_1 swizzle */ static unsigned short _yage_swizbuf[1024*8]; const unsigned short* _src = (const unsigned short*)vram; for (int _p = 0; _p < 1024*8; _p++) { unsigned short _s = _src[_p]; _yage_swizbuf[_p] = ((_s & 0x001Fu) << 11) | ((_s & 0x03E0u) << 1) | ((_s & 0x7C00u) >> 9) | ((_s >> 15) & 0x1u); } glTexSubImage2D(GL_TEXTURE_2D, 0, 0, i*8, 1024, 8, GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, _yage_swizbuf); }
REPL_EOF
    YAGE_REPL="$(cat /tmp/yage_swizzle_replacement.txt | tr -d '\n')"
    YAGE_NEEDLE='glTexSubImage2D(GL_TEXTURE_2D, 0, 0, i*8, 1024, 8, GL_RGBA, GL_UNSIGNED_SHORT_1_5_5_5_REV, vram);'
    YAGE_NEEDLE_E="$(printf '%s' "$YAGE_NEEDLE" | sed 's/[][\.*^$/]/\\&/g')"
    YAGE_REPL_E="$(printf '%s' "$YAGE_REPL"     | sed 's/[\&/]/\\&/g')"
    sed -i '' "s/${YAGE_NEEDLE_E}/${YAGE_REPL_E}/g" "$gpu3d_cpp"
    rm -f /tmp/yage_swizzle_replacement.txt

    # ── 3D MRT attribute buffer GL_RGB → GL_RGBA8 (RE-ENABLED 2026-05-28) ─
    # Per §13 of docs/MELONDS_GLES3_PORTING.md: with the depth+stencil pairing
    # fix in yage_hw_render.c (FBO 0 now complete), AND user confirmation that
    # the black/white blink affects **all** 3D games (Contra 4 + HeartGold,
    # not just HeartGold), the most likely cause is asymmetric per-FBO
    # tolerance of GL_RGB for COLOR_ATTACHMENT1 on Adreno — one of the two
    # MRT FBOs (FramebufferID[0]/[1]) writes correctly, the other does not.
    # The compositor reads them alternately via GLRenderer::FrontBuffer
    # toggling, producing per-frame alternation.
    #
    # GLES3 spec's color-renderable internal-format set is
    # {GL_RGBA4, GL_RGB5_A1, GL_RGB565, GL_RGBA8} — GL_RGB is NOT in it.
    # Forcing GL_RGBA8 makes both MRT FBOs spec-compliant.  The earlier
    # "fully white" regression noted in §11/§12 happened BEFORE the EGL
    # depth+stencil pairing fix; re-test under the new config.
    #
    # The AttrBuffer carries only 8 bits per channel of useful data (R: 6-bit
    # opaque polyID, G: edge flag, B: fog flag), so RGBA8 is overkill but
    # functionally correct.  We patch both occurrences (FramebufferTex[5]
    # at FBO[0] and FramebufferTex[7] at FBO[1]).
    perl -i -pe 's|GL_RGB, ScreenW, ScreenH, 0, GL_RGB, GL_UNSIGNED_BYTE|GL_RGBA8, ScreenW, ScreenH, 0, GL_RGBA, GL_UNSIGNED_BYTE|g' "$gpu3d_cpp"

    echo "    ✓ GPU3D_OpenGL.cpp: GL_UNSIGNED_SHORT_1_5_5_5_REV, GL_BGRA, glMapBufferRange, AttrBuffer GL_RGB→GL_RGBA8"
  fi

  # ── 3b2. GPU3D_OpenGL.cpp: log MRT FBO completeness after SetRenderSettings ─
  # If one of the two MRT FBOs (FramebufferID[0] for buffer-index 0,
  # FramebufferID[1] for buffer-index 1) is incomplete on Adreno, the per-
  # frame alternation we see is explained: GLRenderer::FrontBuffer toggles
  # each frame, so one frame writes to a healthy FBO and the next frame
  # writes to a broken one.  This patch inserts a CHECK_FBO macro into
  # SetRenderSettings right after the glDrawBuffers calls for both FBOs,
  # logging the status code via Android log.  Status 0x8CD5 means COMPLETE;
  # anything else names the exact reason.
  if [ -f "$gpu3d_cpp" ]; then
    perl -0pi -e 's|#include "GPU3D_OpenGL.h"|#include "GPU3D_OpenGL.h"\n#ifdef __ANDROID__\n#include <android/log.h>\n#define MELONDS_3D_LOG(...) __android_log_print(ANDROID_LOG_ERROR, "melonDS-GLES", __VA_ARGS__)\n#else\n#define MELONDS_3D_LOG(...) ((void)0)\n#endif\n#define CHECK_MRT_FBO(label) { GLenum s = glCheckFramebufferStatus(GL_FRAMEBUFFER); if (s != 0x8CD5) MELONDS_3D_LOG("MRT FBO " label " INCOMPLETE: 0x%04x", s); else MELONDS_3D_LOG("MRT FBO " label " complete (0x%04x)", s); }|g' "$gpu3d_cpp"
    # Insert CHECK_MRT_FBO after each glDrawBuffers(2, fbassign) in SetRenderSettings.
    # SetRenderSettings has exactly two such calls (one per FBO).
    perl -0pi -e 's|(\s+)glDrawBuffers\(2, fbassign\);(\s+)glBindFramebuffer\(GL_FRAMEBUFFER, FramebufferID\[1\]\);|$1glDrawBuffers(2, fbassign);$1CHECK_MRT_FBO("FBO[0]");$2glBindFramebuffer(GL_FRAMEBUFFER, FramebufferID[1]);|g' "$gpu3d_cpp"
    perl -0pi -e 's|(\s+)glFramebufferTexture\(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, FramebufferTex\[7\], 0\);\s+glDrawBuffers\(2, fbassign\);|$1glFramebufferTexture(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, FramebufferTex[7], 0);$1glDrawBuffers(2, fbassign);$1CHECK_MRT_FBO("FBO[1]");|g' "$gpu3d_cpp"

    echo "    ✓ GPU3D_OpenGL.cpp: MRT FBO completeness diagnostic injected"
  fi

  # ── 3c. OpenGLSupport.cpp: shader failure diagnostics ────────────────────
  local opengl_support_cpp="$build_dir/src/OpenGLSupport.cpp"
  if [ -f "$opengl_support_cpp" ]; then
    perl -0pi -e 's|#include "OpenGLSupport.h"\n|#include "OpenGLSupport.h"\n#ifdef __ANDROID__\n#include <android/log.h>\n#define MELONDS_GLES_LOG(...) __android_log_print(ANDROID_LOG_ERROR, "melonDS-GLES", __VA_ARGS__)\n#else\n#define MELONDS_GLES_LOG(...) printf(__VA_ARGS__)\n#endif\n|g' "$opengl_support_cpp"
    sed -i '' 's/printf("OpenGL:/MELONDS_GLES_LOG("OpenGL:/g' "$opengl_support_cpp"
    perl -0pi -e 's|\n        FILE\* logf = fopen\("shaderfail\.log", "w"\);\n        fwrite\(fs, len\+1, 1, logf\);\n        fclose\(logf\);|\n        FILE* logf = fopen("shaderfail.log", "w");\n        if (logf)\n        {\n            fwrite(fs, len+1, 1, logf);\n            fclose(logf);\n        }|g' "$opengl_support_cpp"
    sed -i '' 's|FILE\* logf = fopen("shaderfail.log", "w");|FILE* logf = fopen("/data/data/com.yourmateapps.retropal/cache/shaderfail.log", "w");|g' "$opengl_support_cpp"
    
    echo "    ✓ OpenGLSupport.cpp: Android shader logs and safe shaderfail.log write"
  fi

  # ── 3d. Add glGetError tracing to opengl.cpp ──────────────────────────────
  if [ -f "$opengl_cpp" ]; then
    sed -i '' 's/#include <glsm\/glsm.h>/#include <glsm\/glsm.h>\n#ifdef __ANDROID__\n#include <android\/log.h>\n#endif\n#define CHECK_GL(msg) { GLenum err; while((err = glGetError()) != GL_NO_ERROR) { __android_log_print(ANDROID_LOG_ERROR, "melonDS-GLES", "GL ERROR: 0x%04x at %s", err, msg); } }/g' "$opengl_cpp"
    sed -i '' 's/glBindFramebuffer(GL_FRAMEBUFFER, glsm_get_current_framebuffer());/glBindFramebuffer(GL_FRAMEBUFFER, glsm_get_current_framebuffer()); CHECK_GL("glBindFramebuffer");/g' "$opengl_cpp"
    sed -i '' 's/glViewport(0, 0, screen_layout_data.buffer_width, screen_layout_data.buffer_height);/glViewport(0, 0, screen_layout_data.buffer_width, screen_layout_data.buffer_height); CHECK_GL("glViewport");/g' "$opengl_cpp"
    sed -i '' 's/glClear(GL_COLOR_BUFFER_BIT);/glClear(GL_COLOR_BUFFER_BIT); CHECK_GL("glClear");/g' "$opengl_cpp"
    sed -i '' 's/OpenGL::UseShaderProgram(shader);/OpenGL::UseShaderProgram(shader); CHECK_GL("UseShaderProgram");/g' "$opengl_cpp"
    sed -i '' 's/glUnmapBuffer(GL_UNIFORM_BUFFER);/glUnmapBuffer(GL_UNIFORM_BUFFER); CHECK_GL("glUnmapBuffer");/g' "$opengl_cpp"
    sed -i '' 's/glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo);/glBindBufferBase(GL_UNIFORM_BUFFER, 0, ubo); CHECK_GL("glBindBufferBase");/g' "$opengl_cpp"
    sed -i '' 's/GPU::CurGLCompositor->BindOutputTexture(frontbuf);/GPU::CurGLCompositor->BindOutputTexture(frontbuf); CHECK_GL("BindOutputTexture");/g' "$opengl_cpp"
    sed -i '' 's/glBindVertexArray(vao);/glBindVertexArray(vao); CHECK_GL("glBindVertexArray");/g' "$opengl_cpp"
    sed -i '' 's/glDrawArrays(GL_TRIANGLES, 0, screen_layout_data.hybrid_small_screen == SmallScreenLayout::SmallScreenDuplicate ? 18 : 12);/glDrawArrays(GL_TRIANGLES, 0, screen_layout_data.hybrid_small_screen == SmallScreenLayout::SmallScreenDuplicate ? 18 : 12); CHECK_GL("glDrawArrays");/g' "$opengl_cpp"
  fi

  # ── 3d. GPU3D_OpenGL_shaders.h: upgrade to GLES3 ─────────────────────────
  # This file defines kShaderHeader ("#version 140") and all 3D render shaders.
  # It was NOT covered by earlier patches and is the source of "Invalid #version"
  # and float/int type errors on Adreno GLSL ES 3.00.
  local gpu3d_shaders_h="$build_dir/src/GPU3D_OpenGL_shaders.h"
  if [ -f "$gpu3d_shaders_h" ]; then
    # Strip CRLF line endings — Windows git clone may produce CRLF which breaks
    # sed patterns on the same line (pattern does not match due to trailing \r).
    sed -i '' 's/\r//' "$gpu3d_shaders_h"

    # kShaderHeader: upgrade from desktop GLSL 1.40 to GLES 3.00.
    # Use perl for reliability — available in Git for Windows; sed \n escaping
    # inside C string literals is fragile and breaks with CRLF files.
    perl -i -pe 's/#define kShaderHeader "#version 140"/#define kShaderHeader "#version 300 es\\nprecision highp float;\\nprecision highp int;\\nprecision highp sampler2D;\\nprecision highp usampler2D;\\n"/' "$gpu3d_shaders_h"

    # Remove 'smooth' interpolation qualifier (removed in GLES3).
    sed -i '' 's/smooth out /out /g; s/smooth in /in /g' "$gpu3d_shaders_h"

    # Add layout(location) qualifiers for MRT outputs — glBindFragDataLocation
    # is absent from GLES3 and has already been removed from GPU3D_OpenGL.cpp.
    sed -i '' 's/^out vec4 oColor;$/layout(location = 0) out vec4 oColor;/' "$gpu3d_shaders_h"
    sed -i '' 's/^out vec4 oAttr;$/layout(location = 1) out vec4 oAttr;/' "$gpu3d_shaders_h"

    # GLSL ES 3.00 strict typing: integer literal assignments to float components.
    sed -i '' 's/oAttr\.g = 0;/oAttr.g = 0.0;/g' "$gpu3d_shaders_h"
    sed -i '' 's/oAttr\.a = 1;/oAttr.a = 1.0;/g' "$gpu3d_shaders_h"
    sed -i '' 's/oAttr\.g = 1;/oAttr.g = 1.0;/g' "$gpu3d_shaders_h"
    sed -i '' 's/oAttr\.b = 0;/oAttr.b = 0.0;/g' "$gpu3d_shaders_h"
    sed -i '' 's/oAttr\.b = 1;/oAttr.b = 1.0;/g' "$gpu3d_shaders_h"
    sed -i '' 's/ret\.a = 1;/ret.a = 1.0;/g' "$gpu3d_shaders_h"

    # Final edge/fog passes sample the attribute buffer as float vec4s.
    # Adreno's GLES compiler rejects float components compared with int 0.
    perl -i -pe 's/attr\.g != 0(?![.0-9])/attr.g != 0.0/g' "$gpu3d_shaders_h"
    perl -i -pe 's/attr\.b != 0(?![.0-9])/attr.b != 0.0/g' "$gpu3d_shaders_h"

    # Constructors with integer-only arguments are accepted by desktop GLSL
    # but are a common source of strict GLES3 type errors on Adreno.
    sed -i '' 's/vec4(0,0,0,0)/vec4(0.0)/g' "$gpu3d_shaders_h"
    sed -i '' 's/vec4(0,0,0,1)/vec4(0.0, 0.0, 0.0, 1.0)/g' "$gpu3d_shaders_h"
    sed -i '' 's/vec4(0)/vec4(0.0)/g' "$gpu3d_shaders_h"
    sed -i '' 's/65536\.0f/65536.0/g' "$gpu3d_shaders_h"

    # GLSL ES 3.00: no implicit float/int arithmetic.
    # Use perl negative lookahead (?![.0-9]) to avoid double-replacing values
    # that already have a decimal point (e.g. "/ 31.0" → "/ 31.0.0" with \b).
    # vcol.r * 31  →  vcol.r * 31.0  (float * int literal not allowed)
    perl -i -pe 's/vcol\.r \* 31(?![.0-9])/vcol.r * 31.0/g' "$gpu3d_shaders_h"
    # Fix bare integer divisors not already followed by decimal point or digit.
    perl -i -pe 's|/ 31(?![.0-9])|/ 31.0|g' "$gpu3d_shaders_h"
    # Threshold comparisons: 30.5/31, 0.5/31 → use float denominator
    perl -i -pe 's|30\.5/31(?![.0-9])|30.5/31.0|g' "$gpu3d_shaders_h"
    perl -i -pe 's|0\.5/31(?![.0-9])|0.5/31.0|g' "$gpu3d_shaders_h"
    # float(densityfrac)/131072 — should be .0 already but ensure
    perl -i -pe 's|/131072(?![.0-9])|/131072.0|g' "$gpu3d_shaders_h"
    # Safety net: collapse any accidental double-dot literals (N.0.0 → N.0)
    sed -i '' 's/\([0-9][0-9]*\)\.0\.0/\1.0/g' "$gpu3d_shaders_h"

    # GLSL ES 3.00: ternary branches must have the same type.
    # (expr)?1:alpha0  →  (expr)?1.0:alpha0
    sed -i '' 's/)?1:alpha0/)?1.0:alpha0/g' "$gpu3d_shaders_h"
    # return vec4(color.rgb, 1.0); already float — check for bare '1)'
    # mix(A,B,fx) args are float throughout — no fix needed

    echo "    ✓ GPU3D_OpenGL_shaders.h: #version 300 es, layout(location), smooth removed, float types fixed"
  fi

  # ── 3e. GPU_OpenGL_shaders.h: upgrade compositor shaders ────────────────
  # GPU_OpenGL_shaders.h is used by GLCompositor before the 3D renderer is
  # initialised.  Leaving it at desktop GLSL 1.40 makes the OpenGL path fail
  # before the otherwise-patched GPU3D shaders get a chance to run.
  local gpu_shaders_h="$build_dir/src/GPU_OpenGL_shaders.h"
  if [ -f "$gpu_shaders_h" ]; then
    sed -i '' 's/\r//' "$gpu_shaders_h"
    sed -i '' 's/#version 140/#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp usampler2D;/g' "$gpu_shaders_h"
    sed -i '' 's/smooth out /out /g; s/smooth in /in /g' "$gpu_shaders_h"
    sed -i '' 's/out vec4 oColor;/layout(location = 0) out vec4 oColor;/g' "$gpu_shaders_h"

    # GLSL ES 3.00 rejects vec2 * uint and float/int builtins.  The compositor
    # samples the 3D texture at a scaled coordinate, so cast u3DScale once at
    # the arithmetic site instead of changing the uniform ABI.
    sed -i '' 's/vec2(xpos, ypos)\*u3DScale/vec2(xpos, ypos)*float(u3DScale)/g' "$gpu_shaders_h"
    sed -i '' 's/pos\*u3DScale/pos*float(u3DScale)/g' "$gpu_shaders_h"
    sed -i '' 's/mod(fTexcoord\.y, 192)/mod(fTexcoord.y, 192.0)/g' "$gpu_shaders_h"
    sed -i '' 's/step(255, fTexcoord\.x)/step(255.0, fTexcoord.x)/g' "$gpu_shaders_h"
    sed -i '' 's/step(191, ypos)/step(191.0, ypos)/g' "$gpu_shaders_h"
    sed -i '' 's/vec4(63,63,63,31)/vec4(63.0, 63.0, 63.0, 31.0)/g' "$gpu_shaders_h"
    sed -i '' 's/vec4(a)\*(1-x)/vec4(a)*(1.0-x)/g' "$gpu_shaders_h"
    sed -i '' 's/float xpos = val3\.r + xfract;/float xpos = float(val3.r) + xfract;/g' "$gpu_shaders_h"
    sed -i '' 's/vec2 ps = vec2(1,1)/vec2 ps = vec2(1.0, 1.0)/g' "$gpu_shaders_h"

    echo "    ✓ GPU_OpenGL_shaders.h: compositor shaders upgraded to GLSL ES 300"
  fi

  # ── 3f. GPU_OpenGL.cpp + GPU_OpenGL_shaders.h: integer→normalized texture ─
  # CompScreenInputTex is created as GL_RGBA8UI / GL_RGBA_INTEGER (integer
  # texture) and sampled with `usampler2D` + `texelFetch` in the compositor
  # fragment shader.  This is spec-correct GLES3 but multiple Adreno GLES3
  # drivers (Adreno 6xx/7xx) have a well-known bug uploading data via
  # `glTexSubImage2D(..., GL_RGBA_INTEGER, GL_UNSIGNED_BYTE, ...)` to an
  # integer texture — the upload silently succeeds (no GL error) but the
  # texture contents end up all zero, so every `texelFetch` returns
  # uvec4(0,0,0,0), the `dispmode == 1` branch is skipped, and the shader
  # outputs `vec4(0,0,0,1)` — exactly the black-screen symptom on Adreno.
  #
  # Workaround: switch the texture to plain normalized GL_RGBA8 (which has
  # rock-solid driver support for uploads) and convert back to integer in
  # the shader via `_fetchScreen()` which multiplies by 255 and rounds.
  # The byte values that the rest of the shader's bit-ops operate on are
  # preserved 1:1.
  local gpu_opengl_cpp="$build_dir/src/GPU_OpenGL.cpp"
  if [ -f "$gpu_opengl_cpp" ]; then
    sed -i '' 's/GL_RGBA8UI/GL_RGBA8/g'        "$gpu_opengl_cpp"
    sed -i '' 's/GL_RGBA_INTEGER/GL_RGBA/g'    "$gpu_opengl_cpp"

    # ── Compositor diagnostic + corrective clear (NEW 2026-05-28) ─────────
    # The 3D MRT FBOs now both report COMPLETE after the GL_RGBA8 patch,
    # yet the user still sees per-frame black/white alternation in 3D
    # scenes.  That points at the compositor's own double-buffered output:
    # GLCompositor has two FBOs (CompScreenOutputFB[0/1]) and the screen-
    # blit reads CompScreenOutputTex[GPU::FrontBuffer].  If one of the two
    # output FBOs is incomplete or its texture content is in an undefined
    # state, alternation results.
    #
    # This patch:
    #   1. Logs the completeness of CompScreenOutputFB[0/1] right after
    #      SetRenderSettings sets them up.
    #   2. Forces an explicit glClear to opaque black on both output FBOs
    #      so any frame where the compositor's draw fails to cover the
    #      surface starts from a known black state (no undefined-memory
    #      white).
    perl -0pi -e 's|#include "GPU_OpenGL.h"|#include "GPU_OpenGL.h"\n#ifdef __ANDROID__\n#include <android/log.h>\n#define MELONDS_COMP_LOG(...) __android_log_print(ANDROID_LOG_ERROR, "melonDS-GLES", __VA_ARGS__)\n#else\n#define MELONDS_COMP_LOG(...) ((void)0)\n#endif\n#define CHECK_COMP_FBO(idx) { GLenum s = glCheckFramebufferStatus(GL_FRAMEBUFFER); if (s != 0x8CD5) MELONDS_COMP_LOG("Compositor FBO Out[%d] INCOMPLETE: 0x%04x", (idx), s); else MELONDS_COMP_LOG("Compositor FBO Out[%d] complete (0x%04x)", (idx), s); }|g' "$gpu_opengl_cpp"

    # Insert CHECK_COMP_FBO + glClear after each compositor FBO setup in SetRenderSettings.
    # The for-loop iterates i=0..1, configuring CompScreenOutputFB[i].  We append
    # the diagnostic + explicit clear after glDrawBuffers within each iteration.
    perl -0pi -e 's|(glDrawBuffers\(1, fbassign\);)|$1\n        CHECK_COMP_FBO(i);\n        glClearColor(0.0f, 0.0f, 0.0f, 1.0f);\n        glClear(GL_COLOR_BUFFER_BIT);|g' "$gpu_opengl_cpp"

    echo "    ✓ GPU_OpenGL.cpp: ScreenTex GL_RGBA8UI→GL_RGBA8, GL_RGBA_INTEGER→GL_RGBA, output FBO diagnostic + clear"
  fi

  if [ -f "$gpu_shaders_h" ]; then
    # Rename every texelFetch(ScreenTex, ...) call FIRST so the helper we
    # inject in the next step doesn't get its own internal texelFetch call
    # rewritten (which would cause infinite recursion).
    sed -i '' 's|texelFetch(ScreenTex,|_fetchScreen(|g' "$gpu_shaders_h"

    # Switch the sampler type to normalized sampler2D and inject the helper
    # that re-creates the [0..255] integer pixel values the rest of the
    # shader's bit-ops (mbright.b & 0x3, val3.a & 0xF, etc.) expects.
    perl -0pi -e 's|uniform usampler2D ScreenTex;|uniform sampler2D ScreenTex;\n\n// Adreno GLES3 integer-texture upload workaround: CompScreenInputTex is\n// now GL_RGBA8 (normalized).  Recover the [0..255] byte values the rest\n// of the shader treats as ints.  +0.5 rounds-to-nearest so byte N\n// roundtrips exactly (N/255*255 = N-epsilon, +0.5 lands in [N..N+1)).\nivec4 _fetchScreen(ivec2 pos, int lod)\n{\n    return ivec4(texelFetch(ScreenTex, pos, lod) * 255.0 + 0.5);\n}|g' "$gpu_shaders_h"

    # The original code wraps fetches in ivec4(...), e.g.
    #   ivec4 pixel = ivec4(texelFetch(ScreenTex, X, 0));
    # After the rename above this becomes
    #   ivec4 pixel = ivec4(_fetchScreen(X, 0));
    # _fetchScreen already returns ivec4 so the outer ivec4() is a no-op
    # (valid, zero-cost on the GPU).  Leave it alone for minimal patch size.

    echo "    ✓ GPU_OpenGL_shaders.h: ScreenTex normalized + _fetchScreen helper"
  fi

  # ── 4. shaders.h: upgrade GLSL 140 → GLSL ES 300 ─────────────────────────
  local shaders_h="$build_dir/src/libretro/shaders.h"
  if [ -f "$shaders_h" ]; then
    # Upgrade the version directive in both vertex and fragment shaders.
    # GNU sed: \n in the replacement string inserts a real newline character.
    sed -i '' 's/#version 140/#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\nprecision highp usampler2D;/g' "$shaders_h"

    # 'smooth' interpolation qualifier is deprecated / removed in GLSL ES 300.
    sed -i '' 's/smooth out /out /g; s/smooth in /in /g' "$shaders_h"

    # Declare fragment output with explicit location so glBindFragDataLocation
    # (removed above) is not needed and the output slot is unambiguous.
    sed -i '' 's/out vec4 oColor;/layout(location = 0) out vec4 oColor;/g' "$shaders_h"

    # GLSL ES 3.00 strict typing: fpos.y *= -1 fails (int literal → float).
    sed -i '' 's/fpos\.y \*= -1;/fpos.y *= -1.0;/g' "$shaders_h"

    # ── CRITICAL: vertex attribute location binding ──────────────────────
    # The libretro screen-blit shader declares its inputs as `pos` and
    # `texcoord`, but opengl.cpp's setup_opengl() binds attribute locations
    # using `glBindAttribLocation(prog, 0, "vPosition")` and
    # `glBindAttribLocation(prog, 1, "vTexcoord")` — NAMES THAT DON'T EXIST
    # in this shader. Those bind calls are silently ignored and the linker
    # assigns `pos`/`texcoord` to implementation-defined locations.
    #
    # On Adreno (and possibly others) the linker assigns them in a way that
    # doesn't match the C++ glVertexAttribPointer(0, ...) / (1, ...) data
    # streams, so the vertex shader receives garbage positions, all
    # triangles collapse to degenerates, and the final blit to FBO 0 (the
    # EGL window surface) produces NO output — every pixel reads back as
    # (0,0,0,0) including alpha (proving the fragment shader never ran,
    # since it would have written oColor.a = 1.0).
    #
    # Fix: pin the locations explicitly via `layout(location = N)` so
    # `pos` is at location 0 and `texcoord` at location 1, matching the
    # C++ side. The other shaders in the codebase (compositor, 3D MRT)
    # already use `vPosition`/`vTexcoord` which match their bind calls,
    # so this is the only attribute-binding mismatch in the project.
    sed -i '' 's/^in vec2 pos;$/layout(location = 0) in vec2 pos;/' "$shaders_h"
    sed -i '' 's/^in vec2 texcoord;$/layout(location = 1) in vec2 texcoord;/' "$shaders_h"

    echo "    ✓ shaders.h: #version 300 es, precision highp, layout(location=0), fpos.y fix, attribute locations pinned"
  fi

  # ── 5. libretro/opengl.cpp: do not keep GL enabled after setup failure ───
  if [ -f "$opengl_cpp" ]; then
    perl -0pi -e 's|   glsm_ctl\(GLSM_CTL_STATE_BIND, NULL\);\n   setup_opengl\(\);\n\n   if\(using_opengl\)|   glsm_ctl(GLSM_CTL_STATE_BIND, NULL);\n   if (!setup_opengl())\n   {\n      glsm_ctl(GLSM_CTL_STATE_UNBIND, NULL);\n      initialized_glsm = false;\n      using_opengl = false;\n      return;\n   }\n\n   if(using_opengl)|g' "$opengl_cpp"
    echo "    ✓ opengl.cpp: context_reset aborts cleanly when GL setup fails"
  fi

  # ── 6. libretro/opengl.cpp: resize Framebuffer BEFORE first NDS::RunFrame ─
  # Critical correctness fix.  Without this, melonDS allocates GPU::Framebuffer
  # at the SOFTWARE-renderer size (256*192*4 ≈ 192 KB per screen) during
  # retro_load_game (via GPU::SetRenderSettings(false, ...)), then setup_opengl
  # only calls GPU::InitRenderer(true) which switches CurrentRenderer to the
  # accelerated GLRenderer without resizing Framebuffer.  The first
  # NDS::RunFrame after context_reset has the 2D renderer writing
  # (256*3+1)*192*4 ≈ 592 KB into a 192 KB buffer — a 400 KB heap overflow
  # that corrupts whatever object the allocator placed adjacent (in field
  # logs, the Java SurfaceTexture's native RefBase pointer is clobbered with
  # 0x3F=63 max-color bytes and `RefBase::decStrong` SIGSEGVs in the GC
  # finalizer at `0x003f3f3f003f3f3f`).
  #
  # We keep the existing GPU::InitRenderer(true) and ADD a SetRenderSettings
  # call right after.  Replacing with SetRenderSettings alone is unsafe:
  # SetRenderSettings detects `renderer (1) != Renderer (0)` and calls
  # `DeInitRenderer() + InitRenderer(1)`.  DeInitRenderer calls
  # `SoftRenderer::DeInit()` which destroys an internal pthread mutex; the
  # subsequent `unique_ptr = std::make_unique<GLRenderer>()` runs the
  # SoftRenderer destructor which destroys the same mutex AGAIN — bionic
  # catches the double-destroy and aborts with FORTIFY.
  #
  # With InitRenderer(true) first, Renderer == 1 by the time
  # SetRenderSettings runs, so the DeInit/Init block is skipped and only
  # the Framebuffer-resize + compositor/3D texture sizing happens.
  if [ -f "$opengl_cpp" ]; then
    perl -i -pe 's|^   GPU::InitRenderer\(true\);$|   GPU::InitRenderer(true);\n   GPU::SetRenderSettings(true, video_settings);|' "$opengl_cpp"
    echo "    ✓ opengl.cpp: setup_opengl now allocs Framebuffer at accelerated size before first frame"
  fi

  # ── 6b. Application.mk: enable -O3 across the whole Play-Store fleet ─────
  # Upstream melonDS's jni/Application.mk only sets APP_ABI + APP_STL.  The
  # NDK then applies its release default of -O2 with no ARM tuning.  Bumping
  # to -O3 is portable and high-impact for CPU-bound emulation — the ARM
  # JIT hot loop, SPU mixer, and software 2D engine all benefit.  Typical
  # gain on this code shape across ARMv8 SoCs: 10-25 %.
  #
  # Portability constraints (Play Store ships to all Android TVs):
  #   * No -mcpu / -mtune — these tune for a SPECIFIC silicon (Cortex-A55,
  #     A72, etc.) and produce subtly worse codegen on other cores.  The
  #     Play Store fleet ranges from old A7/A53 budget TVs to modern A76+
  #     mid-rangers; we want generic ARMv8-a codegen with -O3, no tuning.
  #   * NEON is mandatory on ARMv8 (already on) and standard on modern
  #     ARMv7 — for armeabi-v7a we only add -mfpu=neon to ensure NEON
  #     codegen is enabled (some old GCCs default to vfp-only).
  #   * -ffast-math reorders fp ops slightly but is widely used in
  #     emulators (Dolphin, PCSX2) without audible/visible regressions for
  #     the SPU 16-channel mixer or 3D engine.  -fno-math-errno is the
  #     safer subset if -ffast-math ever causes audio glitches.
  #   * LTO is intentionally OMITTED — interacts with libretro-common's
  #     hot paths and complicates first-pass A/B.  Add later if needed.
  local app_mk="$build_dir/jni/Application.mk"
  if [ -f "$app_mk" ]; then
    cat > "$app_mk" << 'APPMK_EOF'
APP_ABI := all
APP_STL := c++_static
APP_OPTIM := release
APP_CFLAGS := -O3 -DNDEBUG -ffast-math
APP_CPPFLAGS := -O3 -DNDEBUG -ffast-math
APPMK_EOF
    echo "    ✓ Application.mk: -O3 + -ffast-math + -DNDEBUG (portable, no -mcpu)"
  fi

  # CPU-neutral armeabi-v7a build flags. Keep ARMv7-A + NEON generic and avoid
  # -mcpu/-mtune so this path cannot silently produce a Cortex-specific binary.
  # ThinLTO remains useful and CPU-neutral: it lets -O3 inline melonDS's hot bus
  # read/write helpers across translation units without changing ISA selection.
  #
  # CRITICAL: these LOCAL_* vars must be set BEFORE `include
  # $(BUILD_SHARED_LIBRARY)` — ndk-build only honours LOCAL_CFLAGS set before
  # the module is defined.  Appending to the end of Android.mk is a silent
  # no-op (which is why the prior "portable NEON" append never took effect).
  # Anchor the insertion on the unique `LOCAL_LDFLAGS :=` line — it is the LAST
  # of the module's hard (`:=`) assignments, so our `+=` additions land AFTER
  # them and survive.  (Anchoring earlier, e.g. after LOCAL_MODULE, fails: the
  # subsequent `LOCAL_CFLAGS := $(CORE_FLAGS)` / `LOCAL_CPPFLAGS :=` lines would
  # OVERWRITE our += and silently drop the flags.)  Still well before the
  # BUILD_SHARED_LIBRARY include, and we never touch the include line.
  if [ -f "$android_mk" ]; then
    awk '
      { print }
      /^LOCAL_LDFLAGS[[:space:]]*:=/ && !done {
        print "# ── YAGE: CPU-neutral 32-bit ARM build (generic ARMv7-A + ThinLTO) ──"
        print "ifeq ($(TARGET_ARCH_ABI),armeabi-v7a)"
        print "  LOCAL_CFLAGS   += -march=armv7-a -mfpu=neon -flto=thin"
        print "  LOCAL_CPPFLAGS += -march=armv7-a -mfpu=neon -flto=thin"
        print "  LOCAL_LDFLAGS  += -flto=thin"
        print "endif"
        done=1
      }
    ' "$android_mk" > "$android_mk.tmp" && mv "$android_mk.tmp" "$android_mk"
    echo "    ✓ Android.mk: CPU-neutral armv7-a/NEON + ThinLTO (after LOCAL_MODULE)"
  fi

  # ── 7. screenlayout.cpp: honor GL_ScaleFactor=1 (drop forced 4× floor) ───
  # Earlier investigation (this doc's prior versions) attributed the 4× GPU
  # fillrate hit to a strcmp drift in libretro.cpp.  That turned out to be
  # wrong — upstream libretro.cpp parses melonds_opengl_resolution correctly
  # with `Clamp(var.value[0] - 48, 0, 8)`, so GL_ScaleFactor ends up at 1.
  #
  # The actual fault is in `update_screenlayout` in screenlayout.cpp:
  #
  #     if(opengl)
  #     {
  #         // To avoid some issues the size should be at least 4x the native res
  #         if(video_settings.GL_ScaleFactor > 4)
  #             scale = video_settings.GL_ScaleFactor;
  #         else
  #             scale = 4;
  #     }
  #
  # The unconditional `scale = 4` floor sizes the GL buffer to 4× native
  # **regardless of the user-selected scale factor** whenever the OpenGL
  # renderer is enabled.  For Left/Right layout at 1× that means a 2048×768
  # framebuffer instead of 512×192 — 16× the fragment-shader cost.  On a
  # Mali at 1.5 GHz (Sony BRAVIA BF1) this single line dropped steady-state
  # fps from ~60 to ~30.
  #
  # Patch: let the user-selected GL_ScaleFactor flow through.  The "some
  # issues" the comment alludes to don't reproduce on tested layouts
  # (Left/Right, Top/Bottom).  Hybrid layouts compute their own buffer
  # geometry below and don't depend on this floor.
  local screenlayout_cpp="$build_dir/src/libretro/screenlayout.cpp"
  if [ -f "$screenlayout_cpp" ]; then
    perl -0pi -e '
      s{if\s*\(\s*video_settings\.GL_ScaleFactor\s*>\s*4\s*\)\s*
         \s+scale\s*=\s*video_settings\.GL_ScaleFactor\s*;\s*
         \s+else\s*
         \s+scale\s*=\s*4\s*;}
       {scale = video_settings.GL_ScaleFactor > 0 ? video_settings.GL_ScaleFactor : 1;
            // YAGE: honor user scale; upstream "min 4×" floor was the TV perf killer}xs
    ' "$screenlayout_cpp"
    # Sanity check that the patch landed.
    if grep -q "YAGE: honor user scale" "$screenlayout_cpp"; then
      echo "    ✓ screenlayout.cpp: GL buffer honors GL_ScaleFactor (no forced 4× floor)"
    else
      echo "    ⚠ screenlayout.cpp: GL_ScaleFactor floor patch did NOT match — surface will still be 4× native"
      echo "      Expected to find the 'if (GL_ScaleFactor > 4) ... else scale = 4;' block in update_screenlayout()"
    fi
  fi
}

build_core_abi() {
  local src_dir="$1" core_name="$2" make_target="$3" output_so="$4" abi="$5"
  echo "  [$(date '+%H:%M:%S')] Starting build for $abi architecture..."

  local core_api_level="$API_LEVEL"
  if [ "$core_name" = "mupen64plus_next" ]; then
    # eglGetNativeClientBufferANDROID is available from newer API levels.
    core_api_level=26
  fi

  local triple cc_prefix
  if [ "$abi" = "armeabi-v7a" ]; then
    triple="armv7a-linux-androideabi"
    cc_prefix="${triple}${core_api_level}"
  elif [ "$abi" = "arm64-v8a" ]; then
    triple="aarch64-linux-android"
    cc_prefix="${triple}${core_api_level}"
  elif [ "$abi" = "x86_64" ]; then
    triple="x86_64-linux-android"
    cc_prefix="${triple}${core_api_level}"
  fi

  local cc cxx ar strings_tool
  cc="$(find_executable "$TOOLCHAIN/bin/${cc_prefix}-clang")"
  cxx="$(find_executable "$TOOLCHAIN/bin/${cc_prefix}-clang++")"
  ar="$(find_executable "$TOOLCHAIN/bin/llvm-ar")"
  strings_tool="$(find_executable "$TOOLCHAIN/bin/llvm-strings" || true)"

  echo "  [$(date '+%H:%M:%S')] Building $core_name for $abi (API level $core_api_level)..."

  local core_build_dir="$BUILD_DIR/${core_name}_${abi}"
  echo "  [$(date '+%H:%M:%S')] Preparing build directory..."
  rm -rf "$core_build_dir"
  cp -r "$src_dir" "$core_build_dir"
  echo "  [$(date '+%H:%M:%S')] Build directory prepared"

  if [ "$core_name" = "mupen64plus_next" ]; then
    # The link rewrite uses Make's $(file ...) to spill the (large) object list
    # into a response file, dodging command-line length limits on Windows. That
    # function needs GNU Make >= 4.0; on macOS's bundled Make 3.81 it silently
    # expands to nothing, so the .rsp is never written and the link dies with
    # "no such file: @<core>.rsp". Only patch when $(file) is available —
    # elsewhere (macOS/Linux) the direct link fits easily within ARG_MAX
    # (~25 KB of objects vs a 1 MB+ limit).
    if [ "$(make_major_version)" -ge 4 ]; then
      patch_mupen64plus_makefile "$core_build_dir/Makefile"
    else
      echo "  [$(date '+%H:%M:%S')] make < 4.0 ($(make --version 2>/dev/null | head -1)); using direct link for mupen64plus_next"
    fi
  fi

  if [ "$core_name" = "fceumm" ] || [ "$core_name" = "melonds" ]; then
    if [ "$core_name" = "fceumm" ]; then
      patch_fceumm_core_options_overflow "$core_build_dir"
    elif [ "$core_name" = "melonds" ]; then
      # melonDS is built from the koundinyalanka1/melonDS submodule
      # (native/melonDS), which already carries the GLES3/Android port, the
      # build fixes (platform.cpp <functional>, CommonFuncs.cpp strerror_r
      # guard), and the GL 2D renderer as committed source. No build-time
      # source patching is performed here anymore.
      echo "  [$(date '+%H:%M:%S')] Building melonds for $abi (from submodule source)..."
    fi
    build_android_jni "$core_build_dir" "$output_so" "$abi"
    return
  fi

  if [ "$core_name" = "mgba" ]; then
    build_mgba_cmake "$core_build_dir" "$output_so" "$abi"
    return
  fi

  if [ "$core_name" = "tic80" ]; then
    build_tic80_cmake "$core_build_dir" "$output_so" "$abi"
    return
  fi

  if [ "$core_name" = "fake08" ]; then
    build_fake08_ndk "$core_build_dir" "$output_so" "$abi"
    return
  fi

  local makefile_dir="$core_build_dir"
  local makefile_name="Makefile.libretro"
  if [ -f "$core_build_dir/Makefile.libretro" ]; then
    makefile_dir="$core_build_dir"
    makefile_name="Makefile.libretro"
  elif [ -f "$core_build_dir/Makefile" ]; then
    makefile_dir="$core_build_dir"
    makefile_name="Makefile"
  elif [ -f "$core_build_dir/src/Makefile.libretro" ]; then
    makefile_dir="$core_build_dir/src"
    makefile_name="Makefile.libretro"
  elif [ -f "$core_build_dir/src/Makefile" ]; then
    makefile_dir="$core_build_dir/src"
    makefile_name="Makefile"
  fi

  local make_platform="android"
  local -a extra_args=()
  local -a abi_args=()
  local ldflags_arg="LDFLAGS+=-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"

  if [ "$core_name" = "genesis_plus_gx" ]; then
    make_platform="unix"
    # Bypass Darwin host detection and force shared Android-style output name.
    extra_args+=("TARGET=libgenesis_plus_gx_libretro_android.so" "fpic=-fPIC")
  fi

  if [ "$core_name" = "mednafen_ngp" ] || [ "$core_name" = "mednafen_wswan" ] || [ "$core_name" = "mednafen_pce_fast" ] || [ "$core_name" = "mednafen_supergrafx" ] || [ "$core_name" = "mednafen_vb" ] || [ "$core_name" = "mednafen_psx_hw" ]; then
    make_platform="unix"
    # Some Mednafen makefiles unconditionally append -lrt in unix mode,
    # which is unavailable on Android's bionic libc toolchain.
    if [ -f "$makefile_dir/$makefile_name" ]; then
      sed -i '' 's/LDFLAGS += -lrt/LDFLAGS +=/g' "$makefile_dir/$makefile_name" || true
    fi
    # PSX HW has its own args/ldflags set below; skip the generic ones.
    if [ "$core_name" != "mednafen_psx_hw" ]; then
      ldflags_arg=""
      extra_args+=("TARGET=$output_so" "fpic=-fPIC" "SHARED=-shared -Wl,--no-undefined -Wl,--version-script=link.T -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" "LIBS=-lm")
    fi
  fi

  # Beetle PSX HW — GLES3 build. Must pass GLES=1 + GLES3=1 (not HAVE_OPENGLES3)
  # so Makefile.common selects glsym_es3.c instead of the desktop glsym_gl.c.
  # Use platform=unix (no android platform exists) with TARGET override.
  # HAVE_LIGHTREC=0: default is 1, which enables HAVE_SHM (shm_open not on Android).
  if [ "$core_name" = "mednafen_psx_hw" ]; then
    make_platform="unix"
    extra_args+=("TARGET=$output_so" "HAVE_HW=1" "HAVE_OPENGL=1" "GLES=1" "GLES3=1" "HAVE_LIGHTREC=0" "GL_LIB=-lGLESv3 -lEGL -landroid" "fpic=-fPIC")
    ldflags_arg="LDFLAGS=-shared -Wl,--no-undefined -Wl,--version-script=link.T -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384 -lGLESv3 -lEGL -landroid"
  fi

  if [ "$core_name" = "mupen64plus_next" ]; then
    local nasm_tool
    nasm_tool="$(find_nasm || true)"

    if [ "$abi" = "arm64-v8a" ]; then
      make_platform="arm64_cortex_a53_gles3"
      abi_args+=("ARCH=aarch64" "HAVE_NEON=0")
      ldflags_arg="LDFLAGS=-shared -Wl,--version-script=./libretro/link.T -Wl,--no-undefined -ldl -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    elif [ "$abi" = "x86_64" ]; then
      if [ -z "$nasm_tool" ]; then
        echo "ERROR: NASM is required to build mupen64plus_next for x86_64. Install nasm or extract it under $TOOLS_DIR/nasm."
        return 1
      fi
      make_platform="android-x86_64-gles3"
      abi_args+=("ARCH=x86_64" "WITH_DYNAREC=x86_64" "HAVE_NEON=0" "ASFLAGS=-f elf64 -d ELF_TYPE")
      ldflags_arg="LDFLAGS=-shared -Wl,--version-script=./libretro/link.T -Wl,--no-undefined -Wl,--warn-common -llog -L./custom/android/x86 -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    else
      make_platform="android-gles3"
      abi_args+=("ARCH=arm" "HAVE_NEON=0")
      ldflags_arg="LDFLAGS=-shared -Wl,--version-script=./libretro/link.T -Wl,--no-undefined -Wl,--warn-common -llog -march=armv7-a -L./custom/android/arm -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    fi
    extra_args+=("TARGET=mupen64plus_next_gles3_libretro_android.so" "GL_LIB=-lGLESv3 -lEGL -landroid")
    if [ -n "$nasm_tool" ]; then
      extra_args+=("NASM=$nasm_tool")
    fi
  fi

  if [ "$core_name" = "fceumm" ]; then
    extra_args+=("LIBS=-lm")
  fi

  # Stella (Atari 2600) — GPLv2+ Stella2014 fork. Build via Makefile.libretro
  # in unix mode and force the Android-style output name. Pass -fPIC and the
  # 16 KB page-size linker flags through SHARED so the makefile uses them when
  # linking the final .so (Google Play 16 KB page-size compliance).
  if [ "$core_name" = "stella2014" ]; then
    make_platform="unix"
    extra_args+=("TARGET=$output_so" "fpic=-fPIC" "SHARED=-shared -Wl,--no-undefined -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" "LIBS=-lm")
    ldflags_arg=""
  fi

  echo "  [$(date '+%H:%M:%S')] Cleaning build artifacts..."
  make -C "$makefile_dir" -f "$makefile_name" \
    "platform=$make_platform" ${extra_args[@]+"${extra_args[@]}"} ${abi_args[@]+"${abi_args[@]}"} \
    "CC=$cc" "CXX=$cxx" "AR=$ar" ${strings_tool:+"STRINGS=$strings_tool"} ${ldflags_arg:+"$ldflags_arg"} \
    -j"$JOBS" clean >/dev/null 2>&1 || true

  echo "  [$(date '+%H:%M:%S')] Starting compilation (using $JOBS parallel jobs)..."
  echo "  [$(date '+%H:%M:%S')] ⏳ This may take 2-5 minutes. Build in progress..."
  make -C "$makefile_dir" -f "$makefile_name" \
    "platform=$make_platform" ${extra_args[@]+"${extra_args[@]}"} ${abi_args[@]+"${abi_args[@]}"} \
    "CC=$cc" "CXX=$cxx" "AR=$ar" ${strings_tool:+"STRINGS=$strings_tool"} ${ldflags_arg:+"$ldflags_arg"} \
    -j"$JOBS" 2>&1 | tail -10
  echo "  [$(date '+%H:%M:%S')] Compilation finished"

  local built_so=""
  if [ -f "$makefile_dir/$output_so" ]; then
    built_so="$makefile_dir/$output_so"
  fi
  if [ -z "$built_so" ] && [ "$core_name" = "mupen64plus_next" ] && [ -f "$makefile_dir/mupen64plus_next_gles3_libretro_android.so" ]; then
    built_so="$makefile_dir/mupen64plus_next_gles3_libretro_android.so"
  fi
  if [ -z "$built_so" ]; then
    built_so=$(find "$makefile_dir" \( -name "*.so" -o -name "*.dll" -o -name "*.dylib" \) | grep -v "obj" | head -1)
  fi
  if [ -n "$built_so" ]; then
    echo "  [$(date '+%H:%M:%S')] ✓ Build artifact found: $(basename "$built_so")"
    copy_core_to_jni "$built_so" "$output_so" "$abi"
    echo "  [$(date '+%H:%M:%S')] ✓ Successfully installed to jniLibs"
  else
    echo "  [$(date '+%H:%M:%S')] ✗ ERROR: Build produced no .so file!"
    return 1
  fi
}

build_core() {
  local repo_url="$1" core_name="$2" make_target="$3" output_so="$4"
  local abi built_any=0

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Core: $core_name"
  echo "  Repository: $repo_url"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if ! core_needs_build "$core_name" "$output_so"; then
    echo "  ✓ All requested ABI outputs already exist - skipping"
    return 0
  fi

  echo "  [$(date '+%H:%M:%S')] Fetching source code..."
  local src_root
  if [ "$core_name" = "melonds" ]; then
    # melonDS is vendored as a git submodule — the koundinyalanka1/melonDS fork.
    # Build directly from it instead of cloning libretro/melonDS, so our
    # in-source changes (GLES3 support, the GL 2D renderer) are what gets built.
    src_root="$PROJECT_ROOT/native/melonDS"
    if [ ! -d "$src_root/src" ]; then
      echo "  ✗ Submodule native/melonDS not initialized."
      echo "    Run: git submodule update --init --recursive native/melonDS"
      return 1
    fi
    echo "  [$(date '+%H:%M:%S')] Using submodule source: $src_root"
  else
    clone_or_pull "$repo_url" "$BUILD_DIR/$core_name"
    src_root="$BUILD_DIR/$core_name"
  fi
  echo "  [$(date '+%H:%M:%S')] Source code ready"

  for abi in $ABIS; do
    if should_build_core_abi "$core_name" "$output_so" "$abi"; then
      build_core_abi "$src_root" "$core_name" "$make_target" "$output_so" "$abi"
      built_any=1
    fi
  done

  if [ "$built_any" -eq 0 ]; then
    echo "  ✓ Nothing to build for this core"
  fi
}

build_all_cores() {
  local core_line repo_url core_name make_target output_so

  echo ""
  echo "═══ Building LibRetro Cores ═══"

  for core_line in "${CORES[@]}"; do
    repo_url=$(echo "$core_line" | cut -d'|' -f1)
    core_name=$(echo "$core_line" | cut -d'|' -f2)
    make_target=$(echo "$core_line" | cut -d'|' -f3)
    output_so=$(echo "$core_line" | cut -d'|' -f4)

    core_is_selected "$core_name" "$output_so" || continue
    build_core "$repo_url" "$core_name" "$make_target" "$output_so"
  done
}

strip_libs() {
  local lib_key so

  echo ""
  echo "═══ Stripping Debug Symbols ═══"
  echo "  [$(date '+%H:%M:%S')] Starting symbol stripping..."

  if [ -z "$BUILT_LIBS" ]; then
    echo "  ✓ No newly built libraries to strip"
    return 0
  fi

  for lib_key in $BUILT_LIBS; do
    so="$JNI_LIBS/$lib_key"
    [ -f "$so" ] || continue
    echo "  [$(date '+%H:%M:%S')] Stripping $(basename "$so") (${lib_key%%/*})..."
    "$LLVM_STRIP" "$so" 2>/dev/null && echo "  ✓ stripped $(basename "$so")"
  done
  echo "  [$(date '+%H:%M:%S')] ✓ Stripping complete"
}

verify_alignment() {
  local fail=0 expected_libs="" core_line core_name expected_so abi lib_name so align align_dec

  echo ""
  echo "═══ Verifying 16 KB Alignment ═══"
  echo "  [$(date '+%H:%M:%S')] Starting alignment verification..."

  for core_line in "${CORES[@]}"; do
    core_name=$(echo "$core_line" | cut -d'|' -f2)
    expected_so=$(echo "$core_line" | cut -d'|' -f4)
    core_is_selected "$core_name" "$expected_so" || continue
    expected_libs="$expected_libs $expected_so"
  done

  if [ -z "$expected_libs" ]; then
    echo "ERROR: CORE_FILTER did not match any configured core."
    exit 1
  fi

  for abi in $ABIS; do
    echo "── $abi ──"
    for lib_name in $expected_libs; do
      so="$(core_output_path "$abi" "$lib_name")"
      if [ ! -f "$so" ]; then
        echo "  ✗ $lib_name: missing"
        fail=1
        continue
      fi
      align=$("$READELF" -l "$so" 2>/dev/null | awk '/LOAD/ && !seen {print $NF; seen=1}')
      if [ -z "$align" ]; then
        echo "  ✗ $(basename "$so"): unable to read LOAD alignment"
        fail=1
        continue
      fi
      if [[ "$align" == 0x* ]]; then
        align_dec=$(printf "%d" "$align")
      else
        align_dec=$align
      fi

      if [ "$align_dec" -ge 16384 ]; then
        echo "  ✓ $(basename "$so"): $align"
      else
        echo "  ✗ $(basename "$so"): $align (NOT 16 KB aligned; run FORCE_REBUILD=1 $0)"
        fail=1
      fi
    done
  done

  if [ "$fail" -eq 0 ]; then
    echo ""
    echo "✓ All libraries are 16 KB aligned!"
    echo "  [$(date '+%H:%M:%S')] ✓ Verification complete"
  else
    echo ""
    echo "✗ Some libraries failed alignment check. Missing cores will be built on the next run; existing bad cores need FORCE_REBUILD=1 or manual deletion."
    echo "  [$(date '+%H:%M:%S')] ✗ Verification failed"
    exit 1
  fi
}

build_all_cores
copy_cpp_runtime
strip_libs
verify_alignment

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Build completed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Binaries installed in: $JNI_LIBS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
