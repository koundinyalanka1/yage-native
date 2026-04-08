# RetroPal

RetroPal is a multi-system retro game emulator for Android, built with
Flutter and a custom native libretro frontend written in C.

Supported platforms: Game Boy, Game Boy Color, Game Boy Advance, NES, SNES,
Mega Drive / Genesis, Neo Geo Pocket, WonderSwan, PC Engine, SuperGrafx, and
Nintendo 64.

## Building

### Prerequisites

- Flutter SDK (stable channel)
- Android SDK with NDK r28+
- macOS, Linux, or Windows with bash

### Libretro Cores

The emulator cores are not included in this repository. Build them from
source or fetch pre-built binaries:

```bash
# Build from source (recommended)
./scripts/build_libretro_cores.sh

# Or fetch pre-built from libretro buildbot
./scripts/fetch_libretro_cores.sh
```

Built cores are placed in `android/app/src/main/jniLibs/`.

### App

```bash
flutter pub get
flutter build appbundle
```

## Project Structure

```
lib/           Flutter/Dart application code
native/        C libretro frontend (yage_core)
scripts/       Core build and fetch scripts
android/       Android platform configuration
```

### Native Modules

| File | Purpose |
|------|---------|
| yage_libretro.c | Core lifecycle, dlopen-based core loading |
| yage_env_callback.c | Libretro environment callback handler |
| yage_input.c | Joypad and touch input |
| yage_audio.c | OpenSL ES audio output |
| yage_video.c | Pixel format conversion and rendering |
| yage_hw_render.c | EGL/OpenGL ES hardware rendering |
| yage_gpu_texture.c | AHardwareBuffer zero-copy GPU path |
| yage_frame_loop.c | Native 60fps thread |
| yage_state.c | Save states, SRAM, rewind |
| yage_core_vars.c | Core option storage |
| yage_options_ui.c | Dynamic core options as JSON |
| yage_callbacks.c | Memory mapping helpers |
| yage_rcheevos.c | RetroAchievements integration via rcheevos |

## Licenses

This project is licensed under the GNU General Public License v2 or later.
See [LICENSE](LICENSE) for the full text.

### Emulator Cores (dynamically loaded at runtime)

- **mGBA** (GB/GBC/GBA) — Mozilla Public License 2.0 — https://mgba.io
- **FCEUmm** (NES) — GNU GPL v2 — https://github.com/libretro/libretro-fceumm
- **Snes9x 2010** (SNES) — Non-commercial — https://www.snes9x.com
- **Genesis Plus GX** (Mega Drive) — Non-commercial — https://github.com/ekeeke/Genesis-Plus-GX
- **Mupen64Plus-Next** (N64) — GNU GPL v2+ — https://github.com/libretro/mupen64plus-libretro-nx
- **Mednafen/Beetle NGP** (Neo Geo Pocket) — GNU GPL v2 — https://github.com/libretro/beetle-ngp-libretro
- **Mednafen/Beetle WonderSwan** — GNU GPL v2 — https://github.com/libretro/beetle-wswan-libretro
- **Mednafen/Beetle PCE Fast** (PC Engine) — GNU GPL v2 — https://github.com/libretro/beetle-pce-fast-libretro
- **Mednafen/Beetle SuperGrafx** — GNU GPL v2 — https://github.com/libretro/beetle-supergrafx-libretro

### Static Dependencies

- **rcheevos** — MIT License — https://github.com/RetroAchievements/rcheevos

Cores are loaded as shared libraries at runtime via `dlopen()` and are not
statically linked into the application binary.

## Legal

RetroPal does not include any copyrighted BIOS files or game ROMs.
Users must provide their own legally obtained game files. All trademarks
belong to their respective owners.
