#include "yage_internal.h"

#ifndef _WIN32
_Atomic uint32_t g_keys       = 0;
_Atomic int16_t  g_touch_x    = 0;
_Atomic int16_t  g_touch_y    = 0;
_Atomic int16_t  g_touch_down = 0;
_Atomic int16_t  g_analog_x   = 0;
_Atomic int16_t  g_analog_y   = 0;
#else
volatile uint32_t g_keys       = 0;
volatile int16_t  g_touch_x    = 0;
volatile int16_t  g_touch_y    = 0;
volatile int16_t  g_touch_down = 0;
volatile int16_t  g_analog_x   = 0;
volatile int16_t  g_analog_y   = 0;
#endif

void input_poll_callback(void) {
    
}

int16_t input_state_callback(unsigned port, unsigned device, unsigned index, unsigned id) {
    (void)index;
    
    if (port != 0) return 0;
    
    if (device == RETRO_DEVICE_POINTER) {
#ifndef _WIN32
        if (id == RETRO_DEVICE_ID_POINTER_X) return atomic_load_explicit(&g_touch_x, memory_order_relaxed);
        if (id == RETRO_DEVICE_ID_POINTER_Y) return atomic_load_explicit(&g_touch_y, memory_order_relaxed);
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return atomic_load_explicit(&g_touch_down, memory_order_relaxed);
#else
        if (id == RETRO_DEVICE_ID_POINTER_X) return g_touch_x;
        if (id == RETRO_DEVICE_ID_POINTER_Y) return g_touch_y;
        if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return g_touch_down;
#endif
        return 0;
    }
    
    if (device == RETRO_DEVICE_ANALOG) {
#ifndef _WIN32
        if (id == RETRO_DEVICE_ID_ANALOG_X) return atomic_load_explicit(&g_analog_x, memory_order_relaxed);
        if (id == RETRO_DEVICE_ID_ANALOG_Y) return atomic_load_explicit(&g_analog_y, memory_order_relaxed);
#else
        if (id == RETRO_DEVICE_ID_ANALOG_X) return g_analog_x;
        if (id == RETRO_DEVICE_ID_ANALOG_Y) return g_analog_y;
#endif
        return 0;
    }
    
    if (device != RETRO_DEVICE_JOYPAD) return 0;
    
#ifndef _WIN32
    uint32_t keys = atomic_load_explicit(&g_keys, memory_order_relaxed);
#else
    uint32_t keys = g_keys;
#endif
    
    
    static unsigned poll_log = 0;
    if (keys != 0 && (poll_log++ % 300) == 0) {
        LOGI("Input: input_state_callback id=%u keys=0x%X (core is polling)", id, (unsigned)keys);
    }
    
    
    switch (id) {
        case RETRO_DEVICE_ID_JOYPAD_A:      return (keys & (1 << 0)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_B:      return (keys & (1 << 1)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_SELECT: return (keys & (1 << 2)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_START:  return (keys & (1 << 3)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_RIGHT:  return (keys & (1 << 4)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_LEFT:   return (keys & (1 << 5)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_UP:     return (keys & (1 << 6)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_DOWN:   return (keys & (1 << 7)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_R:      return (keys & (1 << 8)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_L:      return (keys & (1 << 9)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_X:      return (keys & (1 << 10)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_Y:      return (keys & (1 << 11)) ? 1 : 0;
        case RETRO_DEVICE_ID_JOYPAD_MASK: {
            
            uint32_t mask = 0;
            if (keys & (1 << 0))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_A);
            if (keys & (1 << 1))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_B);
            if (keys & (1 << 2))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_SELECT);
            if (keys & (1 << 3))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_START);
            if (keys & (1 << 4))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);
            if (keys & (1 << 5))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);
            if (keys & (1 << 6))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_UP);
            if (keys & (1 << 7))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);
            if (keys & (1 << 8))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_R);
            if (keys & (1 << 9))  mask |= (1 << RETRO_DEVICE_ID_JOYPAD_L);
            if (keys & (1 << 10)) mask |= (1 << RETRO_DEVICE_ID_JOYPAD_X);
            if (keys & (1 << 11)) mask |= (1 << RETRO_DEVICE_ID_JOYPAD_Y);
            return (int16_t)mask;
        }
        default: return 0;
    }
}
