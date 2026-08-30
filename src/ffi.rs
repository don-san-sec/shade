//! Minimal hand-rolled bindings for libghostty (C ABI) and the ObjC shim.
//! Layouts must match include/ghostty.h exactly.

#![allow(non_camel_case_types, dead_code)]

use std::os::raw::{c_char, c_int, c_void};

pub type ghostty_app_t = *mut c_void;
pub type ghostty_surface_t = *mut c_void;
pub type ghostty_config_t = *mut c_void;

// ghostty_platform_e
pub const GHOSTTY_PLATFORM_MACOS: c_int = 1;

// ghostty_input_mods_e (bitmask)
pub const GHOSTTY_MODS_NONE: c_int = 0;
pub const GHOSTTY_MODS_SHIFT: c_int = 1 << 0;
pub const GHOSTTY_MODS_CTRL: c_int = 1 << 1;
pub const GHOSTTY_MODS_ALT: c_int = 1 << 2;
pub const GHOSTTY_MODS_SUPER: c_int = 1 << 3;
pub const GHOSTTY_MODS_CAPS: c_int = 1 << 4;
pub const GHOSTTY_MODS_NUM: c_int = 1 << 5;

// ghostty_input_action_e
pub const GHOSTTY_ACTION_RELEASE: c_int = 0;
pub const GHOSTTY_ACTION_PRESS: c_int = 1;
pub const GHOSTTY_ACTION_REPEAT: c_int = 2;

// ghostty_input_mouse_state_e
pub const GHOSTTY_MOUSE_RELEASE: c_int = 0;
pub const GHOSTTY_MOUSE_PRESS: c_int = 1;

// ghostty_input_mouse_button_e
pub const GHOSTTY_MOUSE_UNKNOWN: c_int = 0;
pub const GHOSTTY_MOUSE_LEFT: c_int = 1;
pub const GHOSTTY_MOUSE_RIGHT: c_int = 2;
pub const GHOSTTY_MOUSE_MIDDLE: c_int = 3;
pub const GHOSTTY_MOUSE_FOUR: c_int = 4;

// ghostty_action_tag_e (selected)
pub const GHOSTTY_ACTION_RING_BELL: c_int = 50;
pub const GHOSTTY_ACTION_SHOW_CHILD_EXITED: c_int = 55;

// ghostty_surface_context_e
pub const GHOSTTY_SURFACE_CONTEXT_WINDOW: c_int = 0;

// ghostty_clipboard_request_e
pub const GHOSTTY_CLIPBOARD_REQUEST_PASTE: c_int = 0;

#[repr(C)]
pub struct ghostty_input_key_s {
    pub action: c_int,
    pub mods: c_int,
    pub consumed_mods: c_int,
    pub keycode: u32,
    pub text: *const c_char,
    pub unshifted_codepoint: u32,
    pub composing: bool,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct ghostty_env_var_s {
    pub key: *const c_char,
    pub value: *const c_char,
}

#[repr(C)]
pub union ghostty_platform_u {
    pub macos_nsview: *mut c_void,
    pub ios_uiview: *mut c_void,
}

#[repr(C)]
pub struct ghostty_surface_config_s {
    pub platform_tag: c_int,
    pub platform: ghostty_platform_u,
    pub userdata: *mut c_void,
    pub scale_factor: f64,
    pub font_size: f32,
    pub working_directory: *const c_char,
    pub command: *const c_char,
    pub env_vars: *mut ghostty_env_var_s,
    pub env_var_count: usize,
    pub initial_input: *const c_char,
    pub wait_after_command: bool,
    pub context: c_int,
}

#[repr(C)]
pub struct ghostty_clipboard_content_s {
    pub mime: *const c_char,
    pub data: *const c_char,
}

/// Runtime callbacks are stored as raw pointer-sized values so that the
/// by-value `ghostty_action_s` callback can point at the ObjC shim's
/// trampoline (quake_action_cb) without Rust needing that struct's ABI.
#[repr(C)]
pub struct ghostty_runtime_config_s {
    pub userdata: *mut c_void,
    pub supports_selection_clipboard: bool,
    pub wakeup_cb: *mut c_void,
    pub action_cb: *mut c_void,
    pub read_clipboard_cb: *mut c_void,
    pub confirm_read_clipboard_cb: *mut c_void,
    pub write_clipboard_cb: *mut c_void,
    pub close_surface_cb: *mut c_void,
}

extern "C" {
    pub fn ghostty_init(argc: usize, argv: *mut *mut c_char) -> c_int;
    pub fn ghostty_config_new() -> ghostty_config_t;
    pub fn ghostty_config_load_default_files(cfg: ghostty_config_t);
    pub fn ghostty_config_load_file(cfg: ghostty_config_t, path: *const c_char);
    pub fn ghostty_config_finalize(cfg: ghostty_config_t);
    pub fn ghostty_config_diagnostics_count(cfg: ghostty_config_t) -> u32;
    pub fn ghostty_app_new(
        runtime: *const ghostty_runtime_config_s,
        cfg: ghostty_config_t,
    ) -> ghostty_app_t;
    pub fn ghostty_app_tick(app: ghostty_app_t);
    pub fn ghostty_surface_new(
        app: ghostty_app_t,
        cfg: *const ghostty_surface_config_s,
    ) -> ghostty_surface_t;
    pub fn ghostty_surface_free(surface: ghostty_surface_t);
    pub fn ghostty_surface_refresh(surface: ghostty_surface_t);
    pub fn ghostty_surface_key(
        surface: ghostty_surface_t,
        key: ghostty_input_key_s,
    );
    pub fn ghostty_surface_key_translation_mods(
        surface: ghostty_surface_t,
        mods: c_int,
    ) -> c_int;
    pub fn ghostty_surface_text(
        surface: ghostty_surface_t,
        text: *const c_char,
        len: usize,
    );
    pub fn ghostty_surface_mouse_button(
        surface: ghostty_surface_t,
        state: c_int,
        button: c_int,
        mods: c_int,
    ) -> bool;
    pub fn ghostty_surface_mouse_pos(
        surface: ghostty_surface_t,
        x: f64,
        y: f64,
        mods: c_int,
    );
    pub fn ghostty_surface_mouse_scroll(
        surface: ghostty_surface_t,
        x: f64,
        y: f64,
        mods: c_int,
    );
    pub fn ghostty_surface_set_size(surface: ghostty_surface_t, w: u32, h: u32);
    pub fn ghostty_surface_set_content_scale(
        surface: ghostty_surface_t,
        scale_x: f64,
        scale_y: f64,
    );
    pub fn ghostty_surface_set_focus(surface: ghostty_surface_t, focused: bool);
    pub fn ghostty_surface_complete_clipboard_request(
        surface: ghostty_surface_t,
        string: *const c_char,
        userdata: *mut c_void,
        err: bool,
    );

    // libdispatch. NB: dispatch_get_main_queue() is a macro in the SDK
    // (resolving to the _dispatch_main_q global); the plain symbol is not
    // exported for arm64, so use the global directly.
    pub static _dispatch_main_q: c_void;
    pub fn dispatch_async_f(
        queue: *mut c_void,
        context: *mut c_void,
        func: extern "C" fn(*mut c_void),
    );

    pub fn free(p: *mut c_void);
}

/// The libdispatch main queue, as `dispatch_get_main_queue()` expands in the
/// SDK headers.
pub fn main_queue() -> *mut c_void {
    unsafe { &_dispatch_main_q as *const c_void as *mut c_void }
}

// ------------------------------------------------------------------ shim
// Mirrors src/quake.h.

#[repr(C)]
pub struct QuakeKey {
    pub keycode: u32,
    pub mods: u64,
    pub action: u8,
    pub event: *const c_void,
}

#[repr(C)]
pub struct QuakeMouse {
    pub kind: u8,
    pub button: u8,
    pub x: f64,
    pub y: f64,
    pub dx: f64,
    pub dy: f64,
    pub momentum: u8,
    pub precise: u8,
    pub mods: u64,
}

#[repr(C)]
pub struct QuakeHooks {
    pub key_down: Option<unsafe extern "C" fn(QuakeKey)>,
    pub key_up: Option<unsafe extern "C" fn(QuakeKey)>,
    pub mouse: Option<unsafe extern "C" fn(QuakeMouse)>,
    pub scroll: Option<unsafe extern "C" fn(QuakeMouse)>,
    pub ime: Option<unsafe extern "C" fn(*const c_char)>,
    pub view_ready: Option<unsafe extern "C" fn(f64, f64, f64)>,
    pub toggle: Option<unsafe extern "C" fn()>,
    pub action: Option<unsafe extern "C" fn(*const c_void, i32, i32) -> bool>,
}

extern "C" {
    pub fn quake_run(hooks: *const QuakeHooks) -> c_int;
    pub fn quake_show();
    pub fn quake_hide();
    pub fn quake_visible() -> bool;
    pub fn quake_content_view() -> *mut c_void;
    pub fn quake_event_chars(event: *const c_void, mods: u64) -> *const c_char;
    pub fn quake_pb_read() -> *mut c_char;
    pub fn quake_pb_write(utf8: *const c_char);
    pub fn quake_beep();
    pub fn quake_logstr(msg: *const c_char);
    pub fn quake_unregister_agent();

    // Only its address is used; libghostty calls it with clang's ABI for
    // the by-value ghostty_action_s parameter.
    pub fn quake_action_cb(app: *mut c_void, a: u64, b: u64) -> bool;
}
