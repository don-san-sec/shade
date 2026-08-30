// quake — AppKit/Carbon shim. All logic lives in Rust; this file only
// owns the parts that must be Objective-C: the panel, the view that
// forwards NSEvents, the global hotkey, and the libghostty action
// trampoline (which must match clang's by-value struct ABI exactly).
//
// Event translation reference: Ghostty's own AppKit surface
// (macos/Sources/Ghostty), MIT licensed.

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#import <os/log.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "quake.h"
#include <ghostty.h>

@class QuakeView;

static QuakeHooks g_hooks;
// Logs via NSLog → unified log. Read with:
//   log show --last 5m --predicate 'process == "Quake"'
static void qlog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:
        [NSString stringWithUTF8String:fmt] arguments:ap];
    va_end(ap);
    os_log(OS_LOG_DEFAULT, "[quake] %{public}@", msg);
}
static NSPanel *g_panel = nil;
static NSRunningApplication *g_prev_app = nil;
static QuakeView *g_view = nil;
static bool g_visible = false;
static id g_esc_monitor = nil;

// "§" on British/ISO keyboards is either the physical section key
// (kVK_ISO_Section = 0x0A, left of Z) or Option+6 (kVK_ANSI_6 = 0x07).
// Register both. Carbon hotkeys need no Accessibility permission.
enum { kQuakeSectionKey = 0x0A, kQuakeSixKey = 0x16 };

#pragma mark - View

@interface QuakeView : NSView
@end

@implementation QuakeView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor IBeamCursor]];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self notifyGeometry];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self notifyGeometry];
}

- (void)notifyGeometry {
    if (!g_hooks.view_ready) return;
    // libghostty wants the framebuffer size (pixels), like Ghostty's own
    // AppKit surface which uses convertToBacking:.
    NSRect fb = [self convertRectToBacking:self.bounds];
    double scale = self.window.screen.backingScaleFactor;
    if (self.window == nil) scale = [NSScreen mainScreen].backingScaleFactor;
    g_hooks.view_ready((double)fb.size.width, (double)fb.size.height, scale);
}

- (void)keyDown:(NSEvent *)event {
    if (g_hooks.key_down) {
        QuakeKey k = {
            .keycode = (uint32_t)event.keyCode,
            .mods = (uint64_t)(event.modifierFlags & 0xFFFF0000ULL),
            .action = event.isARepeat ? 2 : 0,
            .event = (__bridge const void *)event,
        };
        g_hooks.key_down(k);
    }
}

- (void)keyUp:(NSEvent *)event {
    if (g_hooks.key_up) {
        QuakeKey k = {
            .keycode = (uint32_t)event.keyCode,
            .mods = (uint64_t)(event.modifierFlags & 0xFFFF0000ULL),
            .action = 1,
            .event = (__bridge const void *)event,
        };
        g_hooks.key_up(k);
    }
}

// IME / dead-key composition results arrive here.
- (void)insertText:(id)inputString {
    if (g_hooks.ime && [inputString isKindOfClass:[NSString class]]) {
        g_hooks.ime([inputString UTF8String]);
    }
}

- (void)doCommandBySelector:(SEL)selector {
    (void)selector; // swallow
}

- (QuakeMouse)mouseEvent:(NSEvent *)event kind:(uint8_t)kind {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    QuakeMouse m = {
        .kind = kind,
        .button = (uint8_t)(event.buttonNumber > 3 ? 3 : event.buttonNumber),
        .x = (double)p.x,
        .y = (double)(self.bounds.size.height - p.y),
        .mods = (uint64_t)(event.modifierFlags & 0xFFFF0000ULL),
    };
    return m;
}

- (void)mouseMoved:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:0]);
}
- (void)mouseDragged:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:1]);
}
- (void)mouseDown:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:2]);
}
- (void)mouseUp:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:3]);
}
- (void)rightMouseDragged:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:1]);
}
- (void)rightMouseDown:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:2]);
}
- (void)rightMouseUp:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:3]);
}
- (void)otherMouseDragged:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:1]);
}
- (void)otherMouseDown:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:2]);
}
- (void)otherMouseUp:(NSEvent *)event {
    if (g_hooks.mouse) g_hooks.mouse([self mouseEvent:event kind:3]);
}

- (void)scrollWheel:(NSEvent *)event {
    if (!g_hooks.scroll) return;
    QuakeMouse m = [self mouseEvent:event kind:4];
    m.dx = (double)event.scrollingDeltaX;
    m.dy = (double)event.scrollingDeltaY;
    m.momentum = (uint8_t)event.momentumPhase;
    m.precise = event.hasPreciseScrollingDeltas ? 1 : 0;
    g_hooks.scroll(m);
}

@end

#pragma mark - Panel

@interface QuakePanel : NSPanel
@end

@implementation QuakePanel
- (BOOL)canBecomeKey { return YES; }
- (BOOL)canBecomeMain { return NO; }

// Titled windows are constrained to the visible frame (below the menu bar);
// we want true fullscreen coverage.
- (NSRect)constrainFrameRect:(NSRect)frame toScreen:(NSScreen *)screen {
    (void)screen;
    return frame;
}

// Suppress NSBeep for unhandled key events — the terminal handles all keys.
- (void)noResponderFor:(SEL)eventSelector { (void)eventSelector; }

// First click inside the panel makes it key immediately.
- (void)sendEvent:(NSEvent *)event {
    if (event.type == NSEventTypeLeftMouseDown) [self makeKeyWindow];
    [super sendEvent:event];
}
@end

#pragma mark - App delegate

@interface QuakeDelegate : NSObject <NSApplicationDelegate>
@end

@implementation QuakeDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n { (void)n; }
@end

#pragma mark - Hotkey

static OSStatus hotkeyHandler(EventHandlerCallRef call, EventRef event, void *user) {
    (void)call; (void)user;
    EventHotKeyID keyID;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                          NULL, sizeof(keyID), NULL, &keyID) == noErr) {
        // Call the toggle synchronously: the hotkey handler runs on the
        // main thread inside live event processing, which is what lets
        // macOS grant our accessory app focus (user-initiated activation).
        if ((keyID.id == 1 || keyID.id == 2) && g_hooks.toggle) {
            g_hooks.toggle();
        }
    }
    return noErr;
}

#pragma mark - Public API

// Register the bundled launch agent as a proper system login item
// (Background Task Management / SMAppService). Only when running from the
// installed location — dev runs (build/Quake.app) must not register.
void quake_register_agent(void) {
    SMAppService *svc = [SMAppService agentServiceWithPlistName:@"dev.quake.agent.plist"];
    NSError *err = nil;
    if (![svc registerAndReturnError:&err] && err != nil) {
        qlog("agent registration failed: %{public}@", err);
    }
}

void quake_unregister_agent(void) {
    SMAppService *svc = [SMAppService agentServiceWithPlistName:@"dev.quake.agent.plist"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [svc unregisterWithCompletionHandler:^(NSError *err) {
        if (err != nil) qlog("agent unregister failed: %{public}@", err);
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

int quake_run(const QuakeHooks *hooks) {
    g_hooks = *hooks;

    NSApplication *app = [NSApplication sharedApplication];
    if ([[[NSBundle mainBundle] bundlePath] isEqualToString:@"/Applications/Quake.app"]) {
        quake_register_agent();
    }
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [app setDelegate:[[QuakeDelegate alloc] init]];

    // Minimal main menu — apps without one can be denied key status.
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"quake"];
    [appMenu addItemWithTitle:@"Quit quake" action:@selector(terminate:) keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [menubar addItem:appItem];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editItem setSubmenu:editMenu];
    [menubar addItem:editItem];
    [app setMainMenu:menubar];

    // Activation is async on modern macOS; once it lands, make the panel key.
    [[NSNotificationCenter defaultCenter] addObserverForName:
        NSApplicationDidBecomeActiveNotification object:nil queue:nil
        usingBlock:^(NSNotification *n) { (void)n;
            if (g_visible && g_panel != nil) {
                [g_panel makeKeyAndOrderFront:nil];
                if (g_view != nil) [g_panel makeFirstResponder:g_view];
            }
        }];

    // Global hotkey: § with no modifiers.
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallEventHandler(GetEventDispatcherTarget(), hotkeyHandler, 1, &spec, NULL, NULL);
    EventHotKeyID keyID1 = { .signature = 'QAKE', .id = 1 };
    EventHotKeyID keyID2 = { .signature = 'QAKE', .id = 2 };
    static EventHotKeyRef ref1 = NULL, ref2 = NULL;
    // Option+6 types "§" on the British layout.
    OSStatus r1 = RegisterEventHotKey(kQuakeSectionKey, 0, keyID1,
                        GetEventDispatcherTarget(), 0, &ref1);
    OSStatus r2 = RegisterEventHotKey(kQuakeSixKey, optionKey, keyID2,
                        GetEventDispatcherTarget(), 0, &ref2);
    if (r1 != noErr || r2 != noErr) {
        qlog("hotkey registration failed: section=%d opt6=%d", (int)r1, (int)r2);
    }

    // Esc hides while the panel is key.
    g_esc_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
        handler:^NSEvent *(NSEvent *event) {
            if (event.keyCode == 53 && g_hooks.toggle) {
                g_hooks.toggle();
                return nil;
            }
            return event;
        }];

    [app run];
    return 0;
}

static NSScreen *screenForMouse(void) {
    NSPoint mouse = [NSEvent mouseLocation];
    for (NSScreen *screen in [NSScreen screens]) {
        if (NSMouseInRect(mouse, screen.frame, NO)) return screen;
    }
    return [NSScreen mainScreen];
}

void quake_show(void) {
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (front && ![front isEqual:[NSRunningApplication currentApplication]]) {
        g_prev_app = front;
    }
    NSRect frame = screenForMouse().frame;
    if (g_panel == nil) {
        // macOS 27 beta regression: genuinely borderless windows can never
        // become key (Apple forums 814798/814875; also broken in 26.3 RC).
        // Workaround: titled window with a fully hidden titlebar.
        g_panel = [[QuakePanel alloc] initWithContentRect:frame
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
            backing:NSBackingStoreBuffered defer:NO];
        g_panel.titleVisibility = NSWindowTitleHidden;
        g_panel.titlebarAppearsTransparent = YES;
        g_panel.movableByWindowBackground = NO;
        g_panel.movable = NO;
        [[g_panel standardWindowButton:NSWindowCloseButton] setHidden:YES];
        [[g_panel standardWindowButton:NSWindowMiniaturizeButton] setHidden:YES];
        [[g_panel standardWindowButton:NSWindowZoomButton] setHidden:YES];
        [g_panel setLevel:NSStatusWindowLevel]; // above the menu bar
        [g_panel setCollectionBehavior:
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary];
        [g_panel setHidesOnDeactivate:NO];
        [g_panel setOpaque:YES];
        [g_panel setBackgroundColor:[NSColor blackColor]];
        [g_panel setHasShadow:NO];
        [g_panel setAcceptsMouseMovedEvents:YES];
        [g_panel setTitle:@"quake"];
    }
    // Fresh view per show so libghostty attaches to a clean layer.
    g_view = [[QuakeView alloc] initWithFrame:frame];
    [g_view setWantsLayer:YES];
    [g_panel setContentView:g_view];
    [g_panel setInitialFirstResponder:g_view];
    [g_panel setFrame:frame display:YES];
    // macOS 14+ restricts NSApplication self-activation ("cooperative
    // activation"). NSRunningApplication and the Process Manager go through
    // a different path that still honors user-initiated hotkey activation.
    const NSApplicationActivationOptions opts =
        (NSApplicationActivationOptions)(1 << 1); // ignoringOtherApps
    [[NSRunningApplication currentApplication] activateWithOptions:opts];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES];
#pragma clang diagnostic pop
    [g_panel makeKeyAndOrderFront:nil];
    [g_panel makeFirstResponder:g_view];
    g_visible = YES;
}

void quake_hide(void) {
    if (g_panel != nil) [g_panel orderOut:nil];
    g_view = nil;
    g_visible = NO;
    [NSApp deactivate];
    // Return focus to the app that was active before we popped up.
    if (g_prev_app != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [g_prev_app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
    }
}

bool quake_visible(void) { return g_visible; }

void *quake_content_view(void) { return (__bridge void *)g_view; }

// Height of the notch/menu-bar band on the panel's screen (0 if none).
double quake_top_inset(void) {
    NSScreen *screen = g_panel != nil ? g_panel.screen : screenForMouse();
    return (double)screen.safeAreaInsets.top;
}

const char *quake_event_chars(const void *event, uint64_t mods) {
    NSEvent *e = (__bridge NSEvent *)event;
    // Only the four translation-relevant flags are applied.
    const uint64_t keep = NSEventModifierFlagShift | NSEventModifierFlagControl |
                          NSEventModifierFlagOption | NSEventModifierFlagCommand;
    NSEventModifierFlags flags = (NSEventModifierFlags)(mods & keep);
    NSString *s = [e charactersByApplyingModifiers:flags];
    return s == nil ? NULL : [s UTF8String];
}

char *quake_pb_read(void) {
    NSString *s = [[NSPasteboard generalPasteboard]
        stringForType:NSPasteboardTypeString];
    if (s == nil) return NULL;
    const char *utf8 = [s UTF8String];
    return utf8 == NULL ? NULL : strdup(utf8);
}

void quake_pb_write(const char *utf8) {
    NSString *s = [NSString stringWithUTF8String:utf8];
    if (s == nil) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
}

void quake_beep(void) { NSBeep(); }

void quake_logstr(const char *msg) {
    os_log(OS_LOG_DEFAULT, "[quake] %{public}s", msg);
}

void quake_register_agent(void);
void quake_unregister_agent(void);

// libghostty calls action callbacks with a by-value struct; clang's ABI
// for that must be matched exactly, so it is handled here and simplified
// before re-entering Rust.
bool quake_action_cb(void *app, ghostty_target_s target, ghostty_action_s action) {
    (void)target;
    if (!g_hooks.action) return false;
    return g_hooks.action(app, (int32_t)action.tag,
                          (int32_t)action.action.child_exited.exit_code);
}
