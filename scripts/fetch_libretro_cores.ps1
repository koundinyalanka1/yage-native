# Fetch LibRetro cores for Android (NES, SNES, mGBA, Genesis Plus GX)
# Downloads from: https://buildbot.libretro.com/nightly/android/latest/
#
# Run from project root: .\scripts\fetch_libretro_cores.ps1

$baseUrl = "https://buildbot.libretro.com/nightly/android/latest"
$abis = @("armeabi-v7a", "arm64-v8a", "x86_64")
$cores = @(
    @{ name = "fceumm"; file = "fceumm_libretro_android.so" },
    @{ name = "snes9x2010"; file = "snes9x2010_libretro_android.so" },
    @{ name = "mgba"; file = "mgba_libretro_android.so" },
    @{ name = "genesis_plus_gx"; file = "genesis_plus_gx_libretro_android.so" },
    @{ name = "mupen64plus_next"; file = "mupen64plus_next_gles3_libretro_android.so" },
    @{ name = "mednafen_ngp"; file = "mednafen_ngp_libretro_android.so" },
    @{ name = "mednafen_wswan"; file = "mednafen_wswan_libretro_android.so" },
    @{ name = "stella2014"; file = "stella2014_libretro_android.so" },
    @{ name = "mednafen_vb"; file = "mednafen_vb_libretro_android.so" },
    @{ name = "tic80"; file = "tic80_libretro_android.so" },
    @{ name = "fake08"; file = "fake08_libretro_android.so" },
    # Nintendo DS — GPLv3, HLE BIOS via built-in FreeBIOS
    @{ name = "melonds"; file = "melonds_libretro_android.so" },
    # Sony PlayStation 1 (Beetle PSX HW) — GPLv2, RA-supported
    @{ name = "mednafen_psx_hw"; file = "mednafen_psx_hw_libretro_android.so" },
    # Mattel Intellivision — GPLv3, BIOS required
    @{ name = "freeintv"; file = "freeintv_libretro_android.so" }
)

$jniLibs = "android\app\src\main\jniLibs"
if (-not (Test-Path $jniLibs)) {
    New-Item -ItemType Directory -Path $jniLibs -Force | Out-Null
}

foreach ($abi in $abis) {
    $abiDir = Join-Path $jniLibs $abi
    if (-not (Test-Path $abiDir)) {
        New-Item -ItemType Directory -Path $abiDir -Force | Out-Null
    }

    foreach ($core in $cores) {
        $zipUrl = "$baseUrl/$abi/$($core.file).zip"
        $zipPath = Join-Path $abiDir "$($core.file).zip"
        # Android requires the "lib" prefix for .so files bundled in the APK
        $finalName = "lib$($core.file)"
        $finalPath = Join-Path $abiDir $finalName

        Write-Host "Downloading $($core.name) for $abi..."
        try {
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
            Expand-Archive -Path $zipPath -DestinationPath $abiDir -Force
            Remove-Item $zipPath

            # Rename to add "lib" prefix (buildbot files don't have it)
            $extractedPath = Join-Path $abiDir $core.file
            if ((Test-Path $extractedPath) -and ($extractedPath -ne $finalPath)) {
                Move-Item -Path $extractedPath -Destination $finalPath -Force
            }
            Write-Host "  OK: $finalPath"
        } catch {
            Write-Host "  FAILED: $_" -ForegroundColor Red
        }
    }
}

Write-Host "`nDone. Cores placed in $jniLibs"

# ── OpenBIOS (PS1 free fallback BIOS) ───────────────────────────────
# OpenBIOS is GPLv2 licensed and legal to bundle, but the PCSX-Redux
# project does NOT publish a prebuilt openbios.bin — it must be built
# from source. We surface clear instructions instead of hard-failing.
# When the binary is staged at assets/system/openbios.bin the app will
# auto-deploy it to the libretro system directory on first launch.
$openBiosDir = "assets\system"
$openBiosPath = Join-Path $openBiosDir "openbios.bin"
if (-not (Test-Path $openBiosDir)) {
    New-Item -ItemType Directory -Path $openBiosDir -Force | Out-Null
}
Write-Host ""
if (Test-Path $openBiosPath) {
    $size = (Get-Item $openBiosPath).Length
    Write-Host ("OpenBIOS already staged: {0} ({1:N0} bytes)" -f $openBiosPath, $size)
} else {
    Write-Host "OpenBIOS (PS1 free fallback) is NOT auto-downloaded." -ForegroundColor Yellow
    Write-Host "  To enable PS1 launches on mobile without a Sony BIOS:" -ForegroundColor Yellow
    Write-Host "    1. git clone --recursive https://github.com/grumpycoders/pcsx-redux.git"
    Write-Host "    2. cd pcsx-redux && ./dockermake.sh openbios     # Linux/macOS"
    Write-Host "       or: make -C src/mips/openbios                  # if MIPS toolchain installed"
    Write-Host "    3. Copy src/mips/openbios/openbios.bin to assets\system\openbios.bin"
    Write-Host "  PS1 games will still work if the user uploads scph*.bin via the BIOS settings tab."
}

# ── 16 KB page-size alignment check (arm64-v8a) ─────────────────────
Write-Host ""
Write-Host "Checking 16 KB page-size alignment (arm64-v8a only)..."

$arm64Dir = Join-Path $jniLibs "arm64-v8a"
$readelf = $null

# Try to find llvm-readelf from the Android NDK
$ndkHome = $env:ANDROID_NDK_HOME
if (-not $ndkHome) { $ndkHome = $env:ANDROID_HOME }
if ($ndkHome) {
    $readelf = Get-ChildItem -Path $ndkHome -Recurse -Filter "llvm-readelf.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
}

if ($readelf) {
    $misaligned = 0
    foreach ($so in Get-ChildItem -Path $arm64Dir -Filter "*.so" -ErrorAction SilentlyContinue) {
        $output = & $readelf.FullName -l $so.FullName 2>$null
        $loadLine = $output | Where-Object { $_ -match '^\s*LOAD' } | Select-Object -First 1
        if ($loadLine -match '0x([0-9a-fA-F]+)\s*$') {
            $alignHex = $Matches[1]
            $alignDec = [Convert]::ToInt64($alignHex, 16)
            if ($alignDec -lt 16384) {
                Write-Host "  X $($so.Name): aligned to 0x$alignHex (needs 0x4000 for 16 KB)" -ForegroundColor Red
                $misaligned++
            } else {
                Write-Host "  OK $($so.Name): aligned to 0x$alignHex" -ForegroundColor Green
            }
        }
    }
    if ($misaligned -gt 0) {
        Write-Host ""
        Write-Host "================================================================" -ForegroundColor Red
        Write-Host " $misaligned library(ies) are NOT 16 KB aligned." -ForegroundColor Red
        Write-Host " Google Play requires 16 KB page alignment since Aug 2025." -ForegroundColor Red
        Write-Host " Build these cores from source on Linux/macOS via:" -ForegroundColor Yellow
        Write-Host "   ./scripts/build_libretro_cores.sh" -ForegroundColor Yellow
        Write-Host " which links with -Wl,-z,max-page-size=16384 automatically." -ForegroundColor Yellow
        Write-Host "================================================================" -ForegroundColor Red
    } else {
        Write-Host "  All libraries are 16 KB aligned!" -ForegroundColor Green
    }
} else {
    Write-Host "  llvm-readelf not found -- skipping alignment check." -ForegroundColor Yellow
    Write-Host "  Set ANDROID_NDK_HOME or ANDROID_HOME to enable verification."
}

Write-Host ""
Write-Host "Rebuild the app: flutter clean; flutter build apk"
