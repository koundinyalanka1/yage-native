#!/bin/bash
# ── Build LibRetro cores from source for Android (macOS Bash 3.x compatible) ──
set -euo pipefail

NDK_BASE="/Users/koundinya/Library/Android/sdk/ndk"
NDK=$(ls -d "$NDK_BASE"/[0-9]* 2>/dev/null | sort -V | tail -1)

if [ -z "$NDK" ]; then
  echo "ERROR: No NDK found in $NDK_BASE"
  exit 1
fi
echo "Using latest NDK: $NDK"

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
READELF="$TOOLCHAIN/bin/llvm-readelf"

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JNI_LIBS="$PROJECT_ROOT/android/app/src/main/jniLibs"
BUILD_DIR="$PROJECT_ROOT/build/libretro-cores"
API_LEVEL=24

ABIS="armeabi-v7a arm64-v8a x86_64"

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
)

mkdir -p "$BUILD_DIR"

copy_cpp_runtime() {
  echo "═══ Copying libc++ Runtime ═══"

  cp "$TOOLCHAIN/sysroot/usr/lib/arm-linux-androideabi/libc++_shared.so" \
    "$JNI_LIBS/armeabi-v7a/libc++_shared.so"
  cp "$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
    "$JNI_LIBS/arm64-v8a/libc++_shared.so"
  cp "$TOOLCHAIN/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" \
    "$JNI_LIBS/x86_64/libc++_shared.so"

  echo "  ✓ libc++_shared.so copied for armeabi-v7a, arm64-v8a, x86_64"
}

clone_or_pull() {
  local url="$1" dir="$2"
  if [ -d "$dir/.git" ]; then
    echo "  Updating $dir..."
    git -C "$dir" pull --ff-only 2>/dev/null || true
  else
    echo "  Cloning $url..."
    git clone --depth 1 "$url" "$dir"
  fi
}

build_mgba_cmake() {
  local src_dir="$1" output_so="$2" abi="$3"
  local cmake_build="$src_dir/build_$abi"
  mkdir -p "$cmake_build"

  cmake -S "$src_dir" -B "$cmake_build" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-$API_LEVEL" \
    -DANDROID_LD=lld \
    -DCMAKE_C_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" \
    -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_SHARED=OFF -DBUILD_STATIC=OFF \
    -DUSE_EPOXY=OFF -DUSE_SQLITE3=OFF -DUSE_PNG=OFF -DUSE_ZLIB=ON -DM_CORE_GBA=ON -DM_CORE_GB=ON >/dev/null 2>&1

  cmake --build "$cmake_build" --config Release -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) >/dev/null 2>&1

  local built_so=$(find "$cmake_build" -name "*mgba*libretro*.so" -o -name "mgba_libretro.so" | head -1)
  if [ -n "$built_so" ]; then
    mkdir -p "$JNI_LIBS/$abi"
    cp "$built_so" "$JNI_LIBS/$abi/$output_so"
    echo "  ✓ Copied to $JNI_LIBS/$abi/$output_so"
  else
    echo "  ✗ mGBA cmake build produced no .so file!"
    return 1
  fi
}

build_core() {
  local src_dir="$1" core_name="$2" make_target="$3" output_so="$4" abi="$5"
  
  local core_api_level="$API_LEVEL"
  if [ "$core_name" = "mupen64plus_next" ]; then
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

  local cc="$TOOLCHAIN/bin/${cc_prefix}-clang"
  local cxx="$TOOLCHAIN/bin/${cc_prefix}-clang++"
  local ar="$TOOLCHAIN/bin/llvm-ar"

  echo "  Building $core_name for $abi..."

  local core_build_dir="$BUILD_DIR/${core_name}_${abi}"
  rm -rf "$core_build_dir"
  cp -r "$src_dir" "$core_build_dir"

  if [ "$core_name" = "mgba" ]; then
    build_mgba_cmake "$core_build_dir" "$output_so" "$abi"
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
    extra_args+=("TARGET=libgenesis_plus_gx_libretro_android.so" "fpic=-fPIC")
  fi

  if [ "$core_name" = "mednafen_ngp" ] || [ "$core_name" = "mednafen_wswan" ] || [ "$core_name" = "mednafen_pce_fast" ] || [ "$core_name" = "mednafen_supergrafx" ]; then
    make_platform="unix"
    if [ -f "$makefile_dir/$makefile_name" ]; then
      sed -i.bak 's/LDFLAGS += -lrt/LDFLAGS +=/g' "$makefile_dir/$makefile_name" || true
      rm -f "$makefile_dir/$makefile_name.bak"
    fi
    ldflags_arg=""
    extra_args+=("TARGET=$output_so" "fpic=-fPIC" "SHARED=-shared -Wl,--no-undefined -Wl,--version-script=link.T -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384" "LIBS=-lm")
  fi

  if [ "$core_name" = "mupen64plus_next" ]; then
    if [ "$abi" = "arm64-v8a" ]; then
      make_platform="arm64_cortex_a53_gles3"
      abi_args+=("ARCH=aarch64" "HAVE_NEON=0")
      ldflags_arg="LDFLAGS=-shared -Wl,--version-script=./libretro/link.T -Wl,--no-undefined -ldl -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    elif [ "$abi" = "x86_64" ]; then
      make_platform="android-x86_64-gles3"
      abi_args+=("ARCH=x86_64" "WITH_DYNAREC=x86_64" "HAVE_NEON=0" "ASFLAGS=-f elf64 -d ELF_TYPE")
      ldflags_arg="LDFLAGS=-shared -Wl,--version-script=./libretro/link.T -Wl,--no-undefined -Wl,--warn-common -llog -L./custom/android/x86 -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    else
      make_platform="android-gles3"
      abi_args+=("ARCH=arm" "HAVE_NEON=0")
      ldflags_arg="LDFLAGS=-shared -Wl,--version-script=./libretro/link.T -Wl,--no-undefined -Wl,--warn-common -llog -march=armv7-a -L./custom/android/arm -Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384"
    fi
    extra_args+=("TARGET=mupen64plus_next_gles3_libretro_android.so" "GL_LIB=-lGLESv3 -lEGL -landroid")
  fi

  if [ "$core_name" = "fceumm" ]; then
    extra_args+=("LIBS=-lm")
  fi

  make -C "$makefile_dir" -f "$makefile_name" \
    "platform=$make_platform" ${extra_args[@]+"${extra_args[@]}"} ${abi_args[@]+"${abi_args[@]}"} \
    "CC=$cc" "CXX=$cxx" "AR=$ar" ${ldflags_arg:+"$ldflags_arg"} \
    -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) clean >/dev/null 2>&1 || true

  make -C "$makefile_dir" -f "$makefile_name" \
    "platform=$make_platform" ${extra_args[@]+"${extra_args[@]}"} ${abi_args[@]+"${abi_args[@]}"} \
    "CC=$cc" "CXX=$cxx" "AR=$ar" ${ldflags_arg:+"$ldflags_arg"} \
    -j$(sysctl -n hw.ncpu 2>/dev/null || nproc) >/dev/null 2>&1

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
    mkdir -p "$JNI_LIBS/$abi"
    cp "$built_so" "$JNI_LIBS/$abi/$output_so"
    echo "  ✓ Copied to $JNI_LIBS/$abi/$output_so"
  else
    echo "  ✗ Build produced no .so file!"
    return 1
  fi
}

echo ""
echo "═══ Building LibRetro Cores ═══"

for core_line in "${CORES[@]}"; do
  repo_url=$(echo "$core_line" | cut -d'|' -f1)
  core_name=$(echo "$core_line" | cut -d'|' -f2)
  make_target=$(echo "$core_line" | cut -d'|' -f3)
  output_so=$(echo "$core_line" | cut -d'|' -f4)
  
  echo "── $core_name ──"
  clone_or_pull "$repo_url" "$BUILD_DIR/$core_name"

  for abi in $ABIS; do
    build_core "$BUILD_DIR/$core_name" "$core_name" "$make_target" "$output_so" "$abi"
  done
  echo ""
done

copy_cpp_runtime

echo ""
echo "═══ Stripping Debug Symbols ═══"
LLVM_STRIP="$TOOLCHAIN/bin/llvm-strip"
for abi in $ABIS; do
  for so in "$JNI_LIBS/$abi"/*.so; do
    [ -f "$so" ] || continue
    "$LLVM_STRIP" "$so" 2>/dev/null && echo "  ✓ stripped $(basename "$so") ($abi)"
  done
done

echo "═══ Verifying 16 KB Alignment ═══"
FAIL=0
EXPECTED_LIBS=""
for core_line in "${CORES[@]}"; do
  expected_so=$(echo "$core_line" | cut -d'|' -f4)
  EXPECTED_LIBS="$EXPECTED_LIBS $expected_so"
done

for abi in $ABIS; do
  echo "── $abi ──"
  for lib_name in $EXPECTED_LIBS; do
    so="$JNI_LIBS/$abi/$lib_name"
    [ -f "$so" ] || continue
    ALIGN=$("$READELF" -l "$so" 2>/dev/null | awk '/LOAD/ {print $NF; exit}')
    if [[ "$ALIGN" == 0x* ]]; then
      ALIGN_DEC=$(printf "%d" "$ALIGN")
    else
      ALIGN_DEC=$ALIGN
    fi
    
    if [ "$ALIGN_DEC" -ge 16384 ]; then
      echo "  ✓ $(basename "$so"): $ALIGN"
    else
      echo "  ✗ $(basename "$so"): $ALIGN (NOT 16 KB aligned!)"
      FAIL=1
    fi
  done
done

if [ "$FAIL" -eq 0 ]; then
  echo ""
  echo "✓ All libraries are 16 KB aligned!"
else
  echo ""
  echo "✗ Some libraries failed alignment check."
  exit 1
fi
