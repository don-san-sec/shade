//! quake — a §-toggle, fullscreen, libghostty-powered tmux drop-down.
//!
//! Rust owns the logic: libghostty lifecycle, event translation, toggle
//! behaviour. AppKit/Carbon lives in src/shim.m.

mod ffi;

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int, c_void};
use std::path::PathBuf;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};

use ffi::*;

// ------------------------------------------------------------------ state

static APP: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static SURFACE: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static CONFIG: AtomicPtr<c_void> = AtomicPtr::new(ptr::null_mut());
static HIDDEN: AtomicBool = AtomicBool::new(true);

// Written on the main thread only (all hooks run on main).
static mut PENDING_SIZE: (f64, f64, f64) = (0.0, 0.0, 2.0);
static mut COMMAND: Option<CString> = None;
static mut RESOURCES: Option<CString> = None;
// Owned key/value CStrings backing SURFACE_ENV, built once at startup.
static mut SURFACE_ENV_STORAGE: Vec<CString> = Vec::new();
static mut SURFACE_ENV: Vec<ghostty_env_var_s> = Vec::new();

// ------------------------------------------------------------------ config

/// Reads ~/.config/quake/config: optional `command=...` line.
/// Default: no command — the login shell runs, and the user's shell config
/// auto-execs `tmux new-session -A -s main` (their setup). Running tmux
/// ourselves on top would nest and instantly exit.
fn load_command() -> Option<CString> {
    if let Some(dir) = home_config_dir() {
        let path = dir.join("config");
        if let Ok(text) = std::fs::read_to_string(&path) {
            for line in text.lines() {
                let line = line.trim();
                if let Some(rest) = line.strip_prefix("session=") {
                    let cmd = format!("tmux new-session -A -s {}", rest.trim());
                    return Some(CString::new(cmd).expect("command contains NUL"));
                } else if let Some(rest) = line.strip_prefix("command=") {
                    let cmd = rest.trim().to_string();
                    if !cmd.is_empty() {
                        return Some(CString::new(cmd).expect("command contains NUL"));
                    }
                }
            }
        }
    }
    None
}

fn home_config_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config").join("quake"))
}

/// Ghostty runtime resources (terminfo, shell integration) are shipped
/// inside the app bundle when installed.
fn find_resources() -> Option<CString> {
    let exe = std::env::current_exe().ok()?;
    // .../Quake.app/Contents/MacOS/quake
    let resources = exe.parent()?.parent()?.join("Resources").join("ghostty");
    if resources.is_dir() {
        return Some(CString::new(resources.to_str()?).unwrap());
    }
    None
}

// ------------------------------------------------------------------ dispatch

fn log_str(s: &str) {
    if let Ok(c) = CString::new(s) {
        unsafe { quake_logstr(c.as_ptr()) };
    }
}

extern "C" fn tick_thunk(app: *mut c_void) {
    unsafe { ghostty_app_tick(app) };
}

extern "C" fn wakeup_cb(_ud: *mut c_void) {
    let app = APP.load(Ordering::Relaxed);
    if !app.is_null() {
        unsafe { dispatch_async_f(main_queue(), app, tick_thunk) };
    }
}

// ------------------------------------------------------------------ clipboard

struct CompleteCtx {
    surface: ghostty_surface_t,
    userdata: *mut c_void,
}

extern "C" fn complete_thunk(ctx: *mut c_void) {
    let ctx = unsafe { Box::from_raw(ctx as *mut CompleteCtx) };
    unsafe {
        let text = quake_pb_read();
        ghostty_surface_complete_clipboard_request(
            ctx.surface,
            text,
            ctx.userdata,
            false,
        );
        if !text.is_null() {
            free(text as *mut c_void);
        }
    }
}

extern "C" fn read_clipboard_cb(_ud: *mut c_void, _clipboard: c_int, ud: *mut c_void) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() {
        return;
    }
    let ctx = Box::into_raw(Box::new(CompleteCtx { surface, userdata: ud }));
    unsafe { dispatch_async_f(main_queue(), ctx as *mut c_void, complete_thunk) };
}

extern "C" fn confirm_read_clipboard_cb(
    _ud: *mut c_void,
    _title: *const c_char,
    ud: *mut c_void,
    _kind: c_int,
) {
    // Auto-allow: behave exactly like a read.
    read_clipboard_cb(_ud, 0, ud);
}

extern "C" fn write_clipboard_cb(
    _ud: *mut c_void,
    _clipboard: c_int,
    content: *const ghostty_clipboard_content_s,
    len: usize,
    _verified: bool,
) {
    unsafe {
        if content.is_null() || len == 0 {
            return;
        }
        let data = (*content).data;
        if !data.is_null() {
            quake_pb_write(data);
        }
    }
}

// ------------------------------------------------------------------ actions

extern "C" fn action_cb(_app: *const c_void, tag: i32, _exit_code: i32) -> bool {
    match tag {
        t if t == GHOSTTY_ACTION_SHOW_CHILD_EXITED => {
            if !HIDDEN.load(Ordering::Relaxed) {
                hide();
            }
            true
        }
        t if t == GHOSTTY_ACTION_RING_BELL => {
            unsafe { quake_beep() };
            true
        }
        _ => false,
    }
}

extern "C" fn close_surface_cb(_ud: *mut c_void, _process_alive: bool) {
    if !HIDDEN.load(Ordering::Relaxed) {
        hide();
    }
}

// ------------------------------------------------------------------ events

fn ghostty_mods(ns_mods: u64) -> c_int {
    const CAPS: u64 = 1 << 16;
    const SHIFT: u64 = 1 << 17;
    const CONTROL: u64 = 1 << 18;
    const OPTION: u64 = 1 << 19;
    const COMMAND: u64 = 1 << 20;
    const NUMPAD: u64 = 1 << 21;

    let mut mods: c_int = GHOSTTY_MODS_NONE;
    if ns_mods & SHIFT != 0 {
        mods |= GHOSTTY_MODS_SHIFT;
    }
    if ns_mods & CONTROL != 0 {
        mods |= GHOSTTY_MODS_CTRL;
    }
    if ns_mods & OPTION != 0 {
        mods |= GHOSTTY_MODS_ALT;
    }
    if ns_mods & COMMAND != 0 {
        mods |= GHOSTTY_MODS_SUPER;
    }
    if ns_mods & CAPS != 0 {
        mods |= GHOSTTY_MODS_CAPS;
    }
    if ns_mods & NUMPAD != 0 {
        mods |= GHOSTTY_MODS_NUM;
    }
    mods
}

fn ns_translation_mods(ghostty: c_int) -> u64 {
    let mut flags: u64 = 0;
    if ghostty & GHOSTTY_MODS_SHIFT != 0 {
        flags |= 1 << 17;
    }
    if ghostty & GHOSTTY_MODS_CTRL != 0 {
        flags |= 1 << 18;
    }
    if ghostty & GHOSTTY_MODS_ALT != 0 {
        flags |= 1 << 19;
    }
    if ghostty & GHOSTTY_MODS_SUPER != 0 {
        flags |= 1 << 20;
    }
    flags
}

/// GhosttyCharacters logic from Ghostty's NSEvent+Extension.swift: strip
/// control characters (encoded by Ghostty itself) and PUA function keys.
fn sanitized_text(raw: &str) -> Option<CString> {
    let first = raw.chars().next()?;
    let cp = first as u32;
    if cp < 0x20 {
        return None; // control chars are encoded by ghostty from the keycode
    }
    if (0xF700..=0xF8FF).contains(&cp) {
        return None; // function-key PUA range
    }
    CString::new(raw).ok()
}

unsafe extern "C" fn key_down_hook(k: QuakeKey) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() {
        return;
    }

    let mods = ghostty_mods(k.mods);

    // Translation mods handle config such as macos-option-as-alt.
    let tm = ghostty_surface_key_translation_mods(surface, mods);
    let mut owned_text: Option<CString> = None;
    let text_ptr: *const c_char = if k.event.is_null() {
        ptr::null()
    } else {
        let chars = quake_event_chars(k.event, ns_translation_mods(tm));
        if chars.is_null() {
            ptr::null()
        } else {
            let s = CStr::from_ptr(chars).to_string_lossy().into_owned();
            match sanitized_text(&s) {
                Some(c) => {
                    owned_text = Some(c);
                    owned_text.as_ref().unwrap().as_ptr()
                }
                None => ptr::null(),
            }
        }
    };

    // unshifted codepoint: characters with no modifiers
    let mut unshifted: u32 = 0;
    if !k.event.is_null() {
        let raw = quake_event_chars(k.event, 0);
        if !raw.is_null() {
            if let Some(c) = CStr::from_ptr(raw).to_string_lossy().chars().next() {
                unshifted = c as u32;
            }
        }
    }

    let key_ev = ghostty_input_key_s {
        action: if k.action == 2 { GHOSTTY_ACTION_REPEAT } else { GHOSTTY_ACTION_PRESS },
        mods,
        consumed_mods: mods & !(GHOSTTY_MODS_CTRL | GHOSTTY_MODS_SUPER),
        keycode: k.keycode,
        text: text_ptr,
        unshifted_codepoint: unshifted,
        composing: false,
    };
    ghostty_surface_key(surface, key_ev);
    drop(owned_text);
}

unsafe extern "C" fn key_up_hook(k: QuakeKey) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() {
        return;
    }
    let mods = ghostty_mods(k.mods);
    let key_ev = ghostty_input_key_s {
        action: GHOSTTY_ACTION_RELEASE,
        mods,
        consumed_mods: mods & !(GHOSTTY_MODS_CTRL | GHOSTTY_MODS_SUPER),
        keycode: k.keycode,
        text: ptr::null(),
        unshifted_codepoint: 0,
        composing: false,
    };
    ghostty_surface_key(surface, key_ev);
}

fn mouse_button_enum(button: u8) -> c_int {
    match button {
        0 => GHOSTTY_MOUSE_LEFT,
        1 => GHOSTTY_MOUSE_RIGHT,
        2 => GHOSTTY_MOUSE_MIDDLE,
        n => GHOSTTY_MOUSE_FOUR + (n as c_int - 3),
    }
}

unsafe extern "C" fn mouse_hook(m: QuakeMouse) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() {
        return;
    }
    let mods = ghostty_mods(m.mods);
    match m.kind {
        0 | 1 => ghostty_surface_mouse_pos(surface, m.x, m.y, mods),
        2 => {
            ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                mouse_button_enum(m.button),
                mods,
            );
        }
        3 => {
            ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_RELEASE,
                mouse_button_enum(m.button),
                mods,
            );
        }
        _ => {}
    }
}

unsafe extern "C" fn scroll_hook(m: QuakeMouse) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() {
        return;
    }
    // Ghostty multiplies precise (trackpad) deltas by 2 for feel.
    let (mut dx, mut dy) = (m.dx, m.dy);
    if m.precise != 0 {
        dx *= 2.0;
        dy *= 2.0;
    }
    // scroll_mods_t: bit 0 = precise, bits 1-3 = momentum phase.
    let mut scroll_mods: c_int = 0;
    if m.precise != 0 {
        scroll_mods |= 1;
    }
    scroll_mods |= (m.momentum as c_int & 0x7) << 1;
    ghostty_surface_mouse_scroll(surface, dx, dy, scroll_mods);
}

unsafe extern "C" fn ime_hook(utf8: *const c_char) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() || utf8.is_null() {
        return;
    }
    let len = CStr::from_ptr(utf8).to_bytes().len();
    ghostty_surface_text(surface, utf8, len);
}

unsafe extern "C" fn view_ready_hook(w: f64, h: f64, scale: f64) {
    let surface = SURFACE.load(Ordering::Relaxed);
    if surface.is_null() {
        PENDING_SIZE = (w, h, scale);
        return;
    }
    ghostty_surface_set_content_scale(surface, scale, scale);
    ghostty_surface_set_size(surface, w as u32, h as u32);
}

extern "C" fn toggle_hook() {
    if HIDDEN.load(Ordering::Relaxed) {
        show();
    } else {
        hide();
    }
}

// ------------------------------------------------------------------ toggle

fn show() {
    unsafe {
        quake_show();
        let view = quake_content_view();
        if view.is_null() {
            eprintln!("quake: no content view");
            return;
        }
        let app = APP.load(Ordering::Relaxed);
        let (w, h, scale) = PENDING_SIZE;

        let env = &*std::ptr::addr_of!(SURFACE_ENV);
        let mut sc: ghostty_surface_config_s = std::mem::zeroed();
        sc.platform_tag = GHOSTTY_PLATFORM_MACOS;
        sc.platform.macos_nsview = view;
        sc.scale_factor = scale;
        sc.command = match &*std::ptr::addr_of!(COMMAND) {
            Some(c) => c.as_ptr(),
            None => ptr::null(),
        };
        sc.env_vars = env.as_ptr() as *mut ghostty_env_var_s;
        sc.env_var_count = env.len();
        sc.wait_after_command = true;
        sc.context = GHOSTTY_SURFACE_CONTEXT_WINDOW;

        let surface = ghostty_surface_new(app, &sc);
        if surface.is_null() {
            eprintln!("quake: ghostty_surface_new failed");
            quake_hide();
            return;
        }
        SURFACE.store(surface, Ordering::Relaxed);
        ghostty_surface_set_content_scale(surface, scale, scale);
        ghostty_surface_set_size(surface, w as u32, h as u32);

        ghostty_surface_set_focus(surface, true);
        ghostty_surface_refresh(surface);
        HIDDEN.store(false, Ordering::Relaxed);
    }
}

fn hide() {
    let surface = SURFACE.swap(ptr::null_mut(), Ordering::Relaxed);
    unsafe {
        quake_hide();
        if !surface.is_null() {
            ghostty_surface_free(surface);
        }
    }
    HIDDEN.store(true, Ordering::Relaxed);
}

// ------------------------------------------------------------------ main

fn main() {
    unsafe {
        // `quake --unregister-agent`: remove the login item and exit.
        if std::env::args().any(|a| a == "--unregister-agent") {
            quake_unregister_agent();
            return;
        }

        COMMAND = load_command();
        RESOURCES = find_resources();

        // libghostty resolves themes/terminfo/shell-integration from the
        // resources dir; point it at the bundle so `theme = ...` works.
        if let Some(res) = &*std::ptr::addr_of!(RESOURCES) {
            std::env::set_var("GHOSTTY_RESOURCES_DIR", res.to_string_lossy().as_ref());
        }

        // Child environment, built once: launchd spawns us with a bare PATH,
        // so make sure homebrew tools are reachable from the tmux command.
        let storage = &mut *std::ptr::addr_of_mut!(SURFACE_ENV_STORAGE);
        storage.push(CString::new("PATH").unwrap());
        storage.push(
            CString::new("/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
                .unwrap(),
        );
        if let Some(res) = &*std::ptr::addr_of!(RESOURCES) {
            storage.push(CString::new("GHOSTTY_RESOURCES_DIR").unwrap());
            storage.push(res.clone());
        }
        let env = &mut *std::ptr::addr_of_mut!(SURFACE_ENV);
        for pair in storage.chunks(2) {
            env.push(ghostty_env_var_s {
                key: pair[0].as_ptr(),
                value: pair[1].as_ptr(),
            });
        }

        if ghostty_init(0, ptr::null_mut()) != 0 {
            eprintln!("quake: ghostty_init failed");
            std::process::exit(1);
        }

        let cfg = ghostty_config_new();
        // Loads ~/.config/ghostty/config — the user's theme, font, etc.
        ghostty_config_load_default_files(cfg);
        // quake overrides: our panel spawns the login shell whose own
        // config execs tmux; ghostty shell integration in this embedded
        // setup breaks the spawn, so disable it.
        if let Some(dir) = home_config_dir() {
            let ov = dir.join("ghostty-override");
            std::fs::write(&ov, "shell-integration = none\n").ok();
            let ov_c = CString::new(ov.to_str().unwrap()).unwrap();
            ghostty_config_load_file(cfg, ov_c.as_ptr());
        }
        ghostty_config_finalize(cfg);
        CONFIG.store(cfg, Ordering::Relaxed);

        // Surface config diagnostics (e.g. unresolved theme names) once at
        // startup — silent when everything is fine.
        let diags = ghostty_config_diagnostics_count(cfg);
        if diags > 0 {
            log_str(&format!("{} config diagnostics", diags));
        }

        let runtime = ghostty_runtime_config_s {
            userdata: ptr::null_mut(),
            supports_selection_clipboard: false,
            wakeup_cb: wakeup_cb as *const () as usize as *mut c_void,
            action_cb: quake_action_cb as *const () as usize as *mut c_void,
            read_clipboard_cb: read_clipboard_cb as *const () as usize as *mut c_void,
            confirm_read_clipboard_cb: confirm_read_clipboard_cb as *const () as usize as *mut c_void,
            write_clipboard_cb: write_clipboard_cb as *const () as usize as *mut c_void,
            close_surface_cb: close_surface_cb as *const () as usize as *mut c_void,
        };

        let app = ghostty_app_new(&runtime, cfg);
        if app.is_null() {
            eprintln!("quake: ghostty_app_new failed");
            std::process::exit(1);
        }
        APP.store(app, Ordering::Relaxed);

        let hooks = QuakeHooks {
            key_down: Some(key_down_hook),
            key_up: Some(key_up_hook),
            mouse: Some(mouse_hook),
            scroll: Some(scroll_hook),
            ime: Some(ime_hook),
            view_ready: Some(view_ready_hook),
            toggle: Some(toggle_hook),
            action: Some(action_cb),
        };
        quake_run(&hooks);
    }
}
