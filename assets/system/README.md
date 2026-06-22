# Bundled system files

This directory holds asset files that are bundled with the app and deployed to
the runtime libretro system directory on first launch.

## Files

- `openbios.bin` — PlayStation 1 free fallback BIOS, GPLv2 (clean-room
  reimplementation, NOT derived from Sony firmware). Distributed by the
  PCSX-Redux project at https://github.com/grumpycoders/pcsx-redux. Used
  automatically when the user has not provided a real Sony BIOS so PS1 games
  can still launch. Compatibility is limited compared to original BIOS dumps.

Run `scripts/fetch_libretro_cores.ps1` (Windows) or
`scripts/fetch_libretro_cores.sh` (Linux/macOS) to download the latest
`openbios.bin` into this directory before building.
