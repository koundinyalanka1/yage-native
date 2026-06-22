#!/bin/bash
# Fetch LibRetro cores for Android (NES, SNES, mGBA, Genesis Plus GX)
# Downloads from: https://buildbot.libretro.com/nightly/android/latest/
#
# Run from project root: ./scripts/fetch_libretro_cores.sh

BASE_URL="https://buildbot.libretro.com/nightly/android/latest"
ABIS="armeabi-v7a arm64-v8a x86_64"
JNI_LIBS="android/app/src/main/jniLibs"

NDK_BASE="${ANDROID_HOME:-$HOME/Library/Android/sdk}/ndk"
NDK=$(ls -d "$NDK_BASE"/[0-9]* 2>/dev/null | sort -V | tail -1)
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"

mkdir -p "$JNI_LIBS"

for abi in $ABIS; do
  mkdir -p "$JNI_LIBS/$abi"
  
  for core in fceumm_libretro_android.so snes9x2010_libretro_android.so mgba_libretro_android.so genesis_plus_gx_libretro_android.so mupen64plus_next_gles3_libretro_android.so mednafen_ngp_libretro_android.so mednafen_wswan_libretro_android.so stella2014_libretro_android.so mednafen_vb_libretro_android.so tic80_libretro_android.so fake08_libretro_android.so melonds_libretro_android.so mednafen_psx_hw_libretro_android.so freeintv_libretro_android.so; do
    echo "Downloading $core for $abi..."
    if ! curl -fL "$BASE_URL/$abi/$core.zip" -o "/tmp/$core.zip"; then
      echo "  ⚠ Download failed for $core ($abi) — skipping"
      rm -f "/tmp/$core.zip"
      continue
    fi
    if ! unzip -o "/tmp/$core.zip" -d "$JNI_LIBS/$abi"; then
      echo "  ⚠ Invalid ZIP for $core ($abi) — skipping"
      rm -f "/tmp/$core.zip"
      continue
    fi
    rm -f "/tmp/$core.zip"

    # Normalize to lib-prefixed name (Android core loading convention).
    extracted="$JNI_LIBS/$abi/$core"
    normalized="$JNI_LIBS/$abi/lib$core"
    if [ -f "$extracted" ]; then
      mv -f "$extracted" "$normalized"
    fi
  done
done

echo ""
echo "Copying libc++ runtime..."
cp "$TOOLCHAIN/sysroot/usr/lib/arm-linux-androideabi/libc++_shared.so" "$JNI_LIBS/armeabi-v7a/libc++_shared.so"
cp "$TOOLCHAIN/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$JNI_LIBS/arm64-v8a/libc++_shared.so"
cp "$TOOLCHAIN/sysroot/usr/lib/x86_64-linux-android/libc++_shared.so" "$JNI_LIBS/x86_64/libc++_shared.so"

echo ""
echo "Done. Cores placed in $JNI_LIBS"

# ── Strip debug symbols ──────────────────────────────────────────────
echo ""
echo "Stripping debug symbols..."
LLVM_STRIP="$TOOLCHAIN/bin/llvm-strip"
for abi in $ABIS; do
  for so in "$JNI_LIBS/$abi"/*.so; do
    [ -f "$so" ] || continue
    "$LLVM_STRIP" "$so" 2>/dev/null && echo "  ✓ stripped $(basename "$so") ($abi)"
  done
done

# ── 16 KB page-size alignment check ──────────────────────────────────
echo ""
echo "Checking 16 KB page-size alignment (arm64-v8a only)..."
HAS_READELF=true
if ! command -v readelf &>/dev/null; then
  # Try Android NDK's llvm-readelf
  READELF=$(find "$ANDROID_HOME/ndk" -name "llvm-readelf" 2>/dev/null | head -1)
  if [ -z "$READELF" ]; then
    echo "  ⚠ readelf not found — skipping alignment check."
    echo "  Install Android NDK or add llvm-readelf to PATH to verify."
    HAS_READELF=false
  fi
else
  READELF="readelf"
fi

if [ "$HAS_READELF" = true ]; then
  MISALIGNED=0
  for so in "$JNI_LIBS/arm64-v8a"/*.so; do
    ALIGN=$("$READELF" -l "$so" 2>/dev/null | grep -m1 'LOAD' | awk '{print $NF}')
    if [ -n "$ALIGN" ]; then
      ALIGN_DEC=$((ALIGN))
      if [ "$ALIGN_DEC" -lt 16384 ]; then
        echo "  ✗ $(basename "$so"): aligned to $ALIGN (needs 0x4000 for 16 KB)"
        MISALIGNED=$((MISALIGNED + 1))
      else
        echo "  ✓ $(basename "$so"): aligned to $ALIGN"
      fi
    fi
  done
  if [ "$MISALIGNED" -gt 0 ]; then
    echo ""
    echo "⚠ $MISALIGNED library(ies) are NOT 16 KB aligned."
    echo "  These may need to be rebuilt from source with: -Wl,-z,max-page-size=16384"
    echo "  Run: ./scripts/build_libretro_cores.sh"
  else
    echo "  All libraries are 16 KB aligned ✓"
  fi
fi

echo ""

# ── OpenBIOS (PS1 free fallback BIOS) ───────────────────────────────
# OpenBIOS is GPLv2 and legal to bundle, but PCSX-Redux does NOT publish
# a prebuilt openbios.bin — it must be compiled from source. Print clear
# instructions instead of hard-failing. When staged at the path below the
# app deploys it to the libretro system directory on first launch.
OPENBIOS_DIR="assets/system"
OPENBIOS_PATH="$OPENBIOS_DIR/openbios.bin"
mkdir -p "$OPENBIOS_DIR"
echo ""
if [ -f "$OPENBIOS_PATH" ]; then
  echo "OpenBIOS already staged: $OPENBIOS_PATH"
else
  echo "OpenBIOS (PS1 free fallback) is NOT auto-downloaded."
  echo "  To enable PS1 launches on mobile without a Sony BIOS:"
  echo "    1. git clone --recursive https://github.com/grumpycoders/pcsx-redux.git"
  echo "    2. cd pcsx-redux && ./dockermake.sh openbios   # Linux/macOS"
  echo "       or: make -C src/mips/openbios                # if MIPS toolchain installed"
  echo "    3. Copy src/mips/openbios/openbios.bin to $OPENBIOS_PATH"
  echo "  PS1 games will still work if the user uploads scph*.bin via the BIOS settings tab."
fi

echo ""
echo "Rebuild the app: flutter clean && flutter build apk"
