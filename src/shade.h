#ifndef SHADE_H
#define SHADE_H

#include <stdint.h>
#include <stdbool.h>

// Key event extracted from NSEvent by the shim. `event` may be used
// (during the hook, on the main thread) with shade_event_chars() to obtain
// characters for an arbitrary modifier mask.
typedef struct {
    uint32_t keycode;
    uint64_t mods;          // NSEvent modifierFlags, device-independent bits
    uint8_t  action;        // 0 = press, 1 = release, 2 = repeat
    const void *event;      // NSEvent* (opaque), valid during the hook only
} ShadeKey;

typedef struct {
    uint8_t  kind;          // 0 move, 1 drag, 2 down, 3 up
    uint8_t  button;        // 0 left, 1 right, 2 middle, 3+ extra
    double   x, y;          // view coordinates, top-left origin
    double   dx, dy;        // scroll deltas (kind 4 scroll only)
    uint8_t  momentum;      // NSEvent momentumPhase raw (scroll only)
    uint8_t  precise;       // hasPreciseScrollingDeltas (scroll only)
    uint64_t mods;
} ShadeMouse;

typedef struct {
    void (*key_down)(ShadeKey);
    void (*key_up)(ShadeKey);
    void (*mouse)(ShadeMouse);
    void (*scroll)(ShadeMouse);
    void (*ime)(const char *utf8);
    void (*view_ready)(double w, double h, double scale);
    // Global hotkey or key equivalent. `stamp` is the triggering event's
    // time in seconds since boot (NSEvent.timestamp / GetEventTime share
    // that epoch) — used to dedupe the two delivery paths of one press.
    void (*toggle)(double stamp);
    // Simplified libghostty action callback: (app, tag, child_exit_code).
    bool (*action)(const void *app, int32_t tag, int32_t exit_code);
} ShadeHooks;

// Boot NSApplication (accessory) and run the event loop. Blocks forever.
int  shade_run(const ShadeHooks *hooks);

// Show the fullscreen panel on the screen under the mouse, create a fresh
// content view, make key + activate. The view pointer for libghostty is
// then obtained via shade_content_view().
void shade_show(void);
void shade_hide(void);
bool shade_visible(void);
void *shade_content_view(void);
double shade_top_inset(void);

// Characters for `event` translated under `mods` (NSEvent modifier flags;
// only shift/control/option/command of the mask are applied). Returns NULL
// on failure. Valid only during a key hook, on the main thread.
const char *shade_event_chars(const void *event, uint64_t mods);

// Pasteboard helpers (main thread).
char *shade_pb_read(void);   // caller frees
void  shade_pb_write(const char *utf8);
void  shade_beep(void);
void  shade_logstr(const char *msg);
void  shade_register_agent(void);
void  shade_unregister_agent(void);

#endif
