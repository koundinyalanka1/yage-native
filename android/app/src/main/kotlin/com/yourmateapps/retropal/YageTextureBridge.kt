package com.yourmateapps.retropal

import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.view.TextureRegistry

/**
 * Bridge between Flutter's TextureRegistry and the native yage_core library.
 *
 * Creates a SurfaceTexture via TextureRegistry, wraps it in a Surface, and
 * passes the Surface to native code (ANativeWindow).  The native frame loop
 * (or explicit yage_texture_blit calls) write RGBA pixels directly to the
 * Surface — zero-copy from Dart's perspective.
 */
class YageTextureBridge(private val flutterEngine: FlutterEngine) {

    private var surfaceEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null

    companion object {
        init {
            System.loadLibrary("yage_core")
        }

        @JvmStatic
        external fun nativeSetSurface(surface: Surface)

        @JvmStatic
        external fun nativeReleaseSurface()
    }

    /**
     * Create a Flutter texture backed by a SurfaceTexture and pass the
     * underlying Surface to native code for direct pixel writes.
     *
     * @param width  initial buffer width  (e.g. 240 for GBA)
     * @param height initial buffer height (e.g. 160 for GBA)
     * @return the Flutter texture ID to use with the Texture widget
     */
    fun createTexture(width: Int, height: Int): Long {
        destroy()

        val entry = flutterEngine.renderer.createSurfaceTexture()
        surfaceEntry = entry

        val st = entry.surfaceTexture()
        st.setDefaultBufferSize(width, height)

        val surf = Surface(st)
        surface = surf

        nativeSetSurface(surf)

        return entry.id()
    }

    /**
     * Update the SurfaceTexture default buffer size when the emulator
     * resolution changes (e.g. GB 160×144 → SGB 256×224).
     */
    fun updateSize(width: Int, height: Int) {
        surfaceEntry?.surfaceTexture()?.setDefaultBufferSize(width, height)
    }

    /**
     * Release native ANativeWindow, the Surface, and the TextureRegistry
     * entry.  Safe to call even if nothing was created.
     */
    fun destroy() {
        nativeReleaseSurface()
        surface?.release()
        surface = null
        surfaceEntry?.release()
        surfaceEntry = null
    }
}
