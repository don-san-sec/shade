// shade — AppKit/Carbon shim. All logic lives in Rust; this file only
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
#import <objc/message.h>
#import <os/log.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include "shade.h"
#include <ghostty.h>

@class ShadeView;

static ShadeHooks g_hooks;
// Logs via NSLog → unified log. Read with:
//   log show --last 5m --predicate 'process == "Shade"'
static void qlog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:
        [NSString stringWithUTF8String:fmt] arguments:ap];
    va_end(ap);
    os_log(OS_LOG_DEFAULT, "[shade] %{public}@", msg);
}
static NSPanel *g_panel = nil;
static NSRunningApplication *g_prev_app = nil;
static ShadeView *g_view = nil;
static bool g_visible = false;

// The single global toggle is a Cmd-based hotkey, chosen by physical layout:
// Cmd+§ on ISO/British boards (kVK_ISO_Section = 0x0A, the key left of Z),
// Cmd+` on ANSI/US boards (kVK_ANSI_Grave = 0x32, the key left of 1). Only one
// is registered, because Cmd+` is macOS's window-cycle shortcut and we must
// not steal it where § exists. Carbon hotkeys need no Accessibility permission.
//
// Plain § and Option+6 are deliberately NOT bound: they produce the §
// character, which should stay typeable.
enum { kShadeSectionKey = 0x0A, kShadeGraveKey = 0x32, kShadeQKey = 0x0C, kShadeDKey = 0x02 };

#pragma mark - View

@interface ShadeView : NSView
@end

@implementation ShadeView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }
- (BOOL)isOpaque { return YES; }

// When shade is frontmost, Cmd+key events go through the menu's key-equivalent
// handling and the Carbon global hotkey may be preempted — so catch the toggle
// here too. Returns YES (consumed) so it never reaches the terminal.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (event.type == NSEventTypeKeyDown &&
        (event.modifierFlags & NSEventModifierFlagCommand) &&
        !(event.modifierFlags & (NSEventModifierFlagShift |
                                 NSEventModifierFlagOption |
                                 NSEventModifierFlagControl))) {
        const BOOL iso = KBGetLayoutType(LMGetKbdType()) == (OSType)kKeyboardISO;
        const uint16_t want = iso ? kShadeSectionKey : kShadeGraveKey;
        if (event.keyCode == want) {
            if (g_hooks.toggle) g_hooks.toggle();
            return YES;
        }
        // Cmd+Q: send Ctrl+D (EOF) to the shell instead of quitting the app.
        // Forwarded as a synthetic Ctrl+D key event so it is encoded exactly
        // like the real keystroke. Only fires when shade is frontmost; other
        // apps keep their normal Cmd+Q.
        if (event.keyCode == kShadeQKey && g_hooks.key_down) {
            ShadeKey k = {
                .keycode = kShadeDKey,
                .mods = (uint64_t)NSEventModifierFlagControl,
                .action = 0, // press
                .event = NULL,
            };
            g_hooks.key_down(k);
            return YES;
        }
    }
    return [super performKeyEquivalent:event];
}

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
        ShadeKey k = {
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
        ShadeKey k = {
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

- (ShadeMouse)mouseEvent:(NSEvent *)event kind:(uint8_t)kind {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    ShadeMouse m = {
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
    ShadeMouse m = [self mouseEvent:event kind:4];
    m.dx = (double)event.scrollingDeltaX;
    m.dy = (double)event.scrollingDeltaY;
    m.momentum = (uint8_t)event.momentumPhase;
    m.precise = event.hasPreciseScrollingDeltas ? 1 : 0;
    g_hooks.scroll(m);
}

@end

#pragma mark - Panel

// Square corners. macOS 26+ shapes titled windows with rounded corners via
// private NSThemeFrame getters; the setters are no-ops on 27 and the bottom
// corner shape is computed once at window init. shade owns the process and
// has exactly one window, so we override the getters on NSThemeFrame itself,
// before any window is created (called from shade_run).
static CGFloat zeroRadius(id self, SEL _cmd) { (void)self; (void)_cmd; return 0.0; }
static CGSize zeroSize(id self, SEL _cmd) { (void)self; (void)_cmd; return CGSizeZero; }
static BOOL noBool(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }

static void swizzleCornerGetters(void) {
    Class cls = NSClassFromString(@"NSThemeFrame");
    if (cls == Nil) return;
    struct { const char *name; IMP impl; } overrides[] = {
        {"_cornerRadius", (IMP)zeroRadius},
        {"_getCachedDefaultWindowCornerRadius", (IMP)zeroRadius},
        {"_topCornerSize", (IMP)zeroSize},
        {"_bottomCornerSize", (IMP)zeroSize},
        {"_shouldRoundCornersForSurface", (IMP)noBool},
        {"topCornerRounded", (IMP)noBool},
        {"bottomCornerRounded", (IMP)noBool},
    };
    for (unsigned i = 0; i < sizeof(overrides)/sizeof(overrides[0]); i++) {
        SEL sel = NSSelectorFromString([NSString stringWithUTF8String:overrides[i].name]);
        Method m = class_getInstanceMethod(cls, sel);
        if (m != NULL)
            class_replaceMethod(cls, sel, overrides[i].impl, method_getTypeEncoding(m));
    }
}

@interface ShadePanel : NSPanel
@end

@implementation ShadePanel
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

@interface ShadeDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ShadeDelegate
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
        if (keyID.id == 1 && g_hooks.toggle) {
            g_hooks.toggle();
        }
    }
    return noErr;
}

#pragma mark - Public API

// Register the bundled launch agent as a proper system login item
// (Background Task Management / SMAppService). Only when running from the
// installed location — dev runs (build/Shade.app) must not register.
void shade_register_agent(void) {
    SMAppService *svc = [SMAppService agentServiceWithPlistName:@"dev.shade.agent.plist"];
    NSError *err = nil;
    if (![svc registerAndReturnError:&err] && err != nil) {
        qlog("agent registration failed: %{public}@", err);
    }
}

void shade_unregister_agent(void) {
    SMAppService *svc = [SMAppService agentServiceWithPlistName:@"dev.shade.agent.plist"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [svc unregisterWithCompletionHandler:^(NSError *err) {
        if (err != nil) qlog("agent unregister failed: %{public}@", err);
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

int shade_run(const ShadeHooks *hooks) {
    g_hooks = *hooks;

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

    // Square window corners. Must run after NSApplication is initialized
    // (NSThemeFrame is loaded lazily) but before any window is created.
    swizzleCornerGetters();
    [app setDelegate:[[ShadeDelegate alloc] init]];

    // Minimal main menu — apps without one can be denied key status.
    // Items deliberately have NO keyEquivalents: when shade is frontmost the
    // menu bar captures Cmd+key equivalents before the terminal sees them, so
    // Cmd+Q would quit the app and Cmd+C/V/A would never reach the shell.
    NSMenu *menubar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"shade"];
    [appMenu addItemWithTitle:@"Quit shade" action:@selector(terminate:) keyEquivalent:@""];
    [appItem setSubmenu:appMenu];
    [menubar addItem:appItem];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@""];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@""];
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

    // Global hotkey: Cmd+§ (ISO) / Cmd+` (ANSI). See the note by the enum.
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallEventHandler(GetEventDispatcherTarget(), hotkeyHandler, 1, &spec, NULL, NULL);
    EventHotKeyID keyID = { .signature = 'SHAD', .id = 1 };
    static EventHotKeyRef ref = NULL;
    const BOOL iso = KBGetLayoutType(LMGetKbdType()) == (OSType)kKeyboardISO;
    OSStatus r = RegisterEventHotKey(iso ? kShadeSectionKey : kShadeGraveKey,
                        cmdKey, keyID, GetEventDispatcherTarget(), 0, &ref);
    if (r != noErr) {
        qlog("hotkey registration failed: %d", (int)r);
    }

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

void shade_show(void) {
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (front && ![front isEqual:[NSRunningApplication currentApplication]]) {
        g_prev_app = front;
    }
    NSRect frame = screenForMouse().frame;
    if (g_panel == nil) {
        // macOS 27 beta regression: genuinely borderless windows can never
        // become key (Apple forums 814798/814875; also broken in 26.3 RC).
        // Workaround: titled window with a fully hidden titlebar.
        g_panel = [[ShadePanel alloc] initWithContentRect:frame
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
        [g_panel setTitle:@"shade"];
    }
    // Fresh view per show so libghostty attaches to a clean layer.
    g_view = [[ShadeView alloc] initWithFrame:frame];
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

void shade_hide(void) {
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

bool shade_visible(void) { return g_visible; }

void *shade_content_view(void) { return (__bridge void *)g_view; }

// Height of the notch/menu-bar band on the panel's screen (0 if none).
double shade_top_inset(void) {
    NSScreen *screen = g_panel != nil ? g_panel.screen : screenForMouse();
    return (double)screen.safeAreaInsets.top;
}

const char *shade_event_chars(const void *event, uint64_t mods) {
    NSEvent *e = (__bridge NSEvent *)event;
    // Only the four translation-relevant flags are applied.
    const uint64_t keep = NSEventModifierFlagShift | NSEventModifierFlagControl |
                          NSEventModifierFlagOption | NSEventModifierFlagCommand;
    NSEventModifierFlags flags = (NSEventModifierFlags)(mods & keep);
    NSString *s = [e charactersByApplyingModifiers:flags];
    return s == nil ? NULL : [s UTF8String];
}

char *shade_pb_read(void) {
    NSString *s = [[NSPasteboard generalPasteboard]
        stringForType:NSPasteboardTypeString];
    if (s == nil) return NULL;
    const char *utf8 = [s UTF8String];
    return utf8 == NULL ? NULL : strdup(utf8);
}

void shade_pb_write(const char *utf8) {
    NSString *s = [NSString stringWithUTF8String:utf8];
    if (s == nil) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:s forType:NSPasteboardTypeString];
}

void shade_beep(void) { NSBeep(); }

void shade_logstr(const char *msg) {
    os_log(OS_LOG_DEFAULT, "[shade] %{public}s", msg);
}

void shade_register_agent(void);
void shade_unregister_agent(void);

// libghostty calls action callbacks with a by-value struct; clang's ABI
// for that must be matched exactly, so it is handled here and simplified
// before re-entering Rust.
bool shade_action_cb(void *app, ghostty_target_s target, ghostty_action_s action) {
    (void)target;
    if (!g_hooks.action) return false;
    return g_hooks.action(app, (int32_t)action.tag,
                          (int32_t)action.action.child_exited.exit_code);
}
