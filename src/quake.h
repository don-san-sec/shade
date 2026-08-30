#ifndef QUAKE_H
#define QUAKE_H

#include <stdint.h>
#include <stdbool.h>

// Key event extracted from NSEvent by the shim. `event` may be used
// (during the hook, on the main thread) with quake_event_chars() to obtain
// characters for an arbitrary modifier mask.
typedef struct {
    uint32_t keycode;
    uint64_t mods;          // NSEvent modifierFlags, device-independent bits
    uint8_t  action;        // 0 = press, 1 = release, 2 = repeat
    const void *event;      // NSEvent* (opaque), valid during the hook only
} QuakeKey;

typedef struct {
    uint8_t  kind;          // 0 move, 1 drag, 2 down, 3 up
    uint8_t  button;        // 0 left, 1 right, 2 middle, 3+ extra
    double   x, y;          // view coordinates, top-left origin
    double   dx, dy;        // scroll deltas (kind 4 scroll only)
    uint8_t  momentum;      // NSEvent momentumPhase raw (scroll only)
    uint8_t  precise;       // hasPreciseScrollingDeltas (scroll only)
    uint64_t mods;
} QuakeMouse;

typedef struct {
    void (*key_down)(QuakeKey);
    void (*key_up)(QuakeKey);
    void (*mouse)(QuakeMouse);
    void (*scroll)(QuakeMouse);
    void (*ime)(const char *utf8);
    void (*view_ready)(double w, double h, double scale);
    void (*toggle)(void);   // global hotkey or Esc
    // Simplified libghostty action callback: (app, tag, child_exit_code).
    bool (*action)(const void *app, int32_t tag, int32_t exit_code);
} QuakeHooks;

// Boot NSApplication (accessory) and run the event loop. Blocks forever.
int  quake_run(const QuakeHooks *hooks);

// Show the fullscreen panel on the screen under the mouse, create a fresh
// content view, make key + activate. The view pointer for libghostty is
// then obtained via quake_content_view().
void quake_show(void);
void quake_hide(void);
bool quake_visible(void);
void *quake_content_view(void);

// Characters for `event` translated under `mods` (NSEvent modifier flags;
// only shift/control/option/command of the mask are applied). Returns NULL
// on failure. Valid only during a key hook, on the main thread.
const char *quake_event_chars(const void *event, uint64_t mods);

// Pasteboard helpers (main thread).
char *quake_pb_read(void);   // caller frees
void  quake_pb_write(const char *utf8);
void  quake_beep(void);
void  quake_logstr(const char *msg);

#endif
