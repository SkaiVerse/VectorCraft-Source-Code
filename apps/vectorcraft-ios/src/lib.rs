//! VectorCraft for iPad: the engine and egui interface, drawn with Metal, driven by a Swift shell.
//!
//! Swift owns the window, Files, printing, the clipboard and the iPad's keyboard, pointer, fingers
//! and Apple Pencil. This crate owns the app, the egui context and the graphics, and builds the
//! frame's input itself (no winit, no eframe).
#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

use egui::{Event, PointerButton, Pos2, TouchDeviceId, TouchId, TouchPhase};
use vectorcraft_engine::Session;
use vectorcraft_ui_egui::place::{PlaceArrival, PlaceInbox};
use vectorcraft_ui_egui::print::{PrintJob, PrintService, Printer};
use vectorcraft_ui_egui::stylus::{PenPose, PenSample, StylusFeed};
use vectorcraft_ui_egui::touch::{self, Source};
use vectorcraft_ui_egui::{Inbox, PickedInbox, Services, UiState, VectorcraftApp};

// ---------------------------------------------------------------------------------------------
// Callbacks into Swift (must match VectorCraft-Bridging-Header.h, field for field)
// ---------------------------------------------------------------------------------------------

#[repr(C)]
#[derive(Clone, Copy)]
pub struct VCCallbacks {
    pub user: *mut c_void,
    pub open_files: Option<unsafe extern "C" fn(*mut c_void)>,
    pub place_files: Option<unsafe extern "C" fn(*mut c_void)>,
    pub save_file: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const u8, usize)>,
    pub open_url: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub copy_text: Option<unsafe extern "C" fn(*mut c_void, *const c_char)>,
    pub paste_text: Option<unsafe extern "C" fn(*mut c_void) -> *const c_char>,
    pub print_pdf: Option<unsafe extern "C" fn(*mut c_void, *const c_char, *const u8, usize)>,
}

// ---------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn documents_dir() -> Option<PathBuf> {
    home().map(|h| h.join("Documents"))
}

fn config_dir() -> Option<PathBuf> {
    home().map(|h| h.join("Library/Application Support/VectorCraft"))
}

fn note(msg: &str) {
    use std::io::Write;
    let Some(dir) = documents_dir() else { return };
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("VectorCraft-log.txt")) {
        let _ = writeln!(f, "[rust] {msg}");
    }
}

fn cstring(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap_or_default()
}

unsafe fn from_c(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

unsafe fn bytes_from(data: *const u8, len: usize) -> Vec<u8> {
    if data.is_null() || len == 0 {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(data, len) }.to_vec()
    }
}

fn guard<R>(default: R, f: impl FnOnce() -> R) -> R {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(default)
}

fn to_mods(m: u32) -> egui::Modifiers {
    // Only Apple's modifier rules: Command is the shortcut key, Control stays Control.
    let cmd = m & 8 != 0;
    egui::Modifiers { alt: m & 4 != 0, ctrl: m & 2 != 0, shift: m & 1 != 0, mac_cmd: cmd, command: cmd }
}

fn hid_to_key(hid: u32) -> Option<egui::Key> {
    use egui::Key;
    const LETTERS: [Key; 26] = [
        Key::A, Key::B, Key::C, Key::D, Key::E, Key::F, Key::G, Key::H, Key::I, Key::J, Key::K, Key::L, Key::M,
        Key::N, Key::O, Key::P, Key::Q, Key::R, Key::S, Key::T, Key::U, Key::V, Key::W, Key::X, Key::Y, Key::Z,
    ];
    const DIGITS: [Key; 9] =
        [Key::Num1, Key::Num2, Key::Num3, Key::Num4, Key::Num5, Key::Num6, Key::Num7, Key::Num8, Key::Num9];
    const FKEYS: [Key; 12] =
        [Key::F1, Key::F2, Key::F3, Key::F4, Key::F5, Key::F6, Key::F7, Key::F8, Key::F9, Key::F10, Key::F11, Key::F12];
    Some(match hid {
        0x04..=0x1D => LETTERS[(hid - 0x04) as usize],
        0x1E..=0x26 => DIGITS[(hid - 0x1E) as usize],
        0x27 => Key::Num0,
        0x28 => Key::Enter,
        0x29 => Key::Escape,
        0x2A => Key::Backspace,
        0x2B => Key::Tab,
        0x2C => Key::Space,
        0x2D => Key::Minus,
        0x2E => Key::Equals,
        0x2F => Key::OpenBracket,
        0x30 => Key::CloseBracket,
        0x31 => Key::Backslash,
        0x33 => Key::Semicolon,
        0x34 => Key::Quote,
        0x35 => Key::Backtick,
        0x36 => Key::Comma,
        0x37 => Key::Period,
        0x38 => Key::Slash,
        0x3A..=0x45 => FKEYS[(hid - 0x3A) as usize],
        0x49 => Key::Insert,
        0x4A => Key::Home,
        0x4B => Key::PageUp,
        0x4C => Key::Delete,
        0x4D => Key::End,
        0x4E => Key::PageDown,
        0x4F => Key::ArrowRight,
        0x50 => Key::ArrowLeft,
        0x51 => Key::ArrowDown,
        0x52 => Key::ArrowUp,
        _ => return None,
    })
}

// ---------------------------------------------------------------------------------------------
// Preferences (the same files as the desktop app, in the app's own folder)
// ---------------------------------------------------------------------------------------------

fn load_prefs(app: &mut VectorcraftApp) {
    let Some(dir) = config_dir() else { return };
    let Ok(bytes) = std::fs::read(dir.join("ui.json")) else { return };
    match serde_json::from_slice::<UiState>(&bytes) {
        Ok(ui) => {
            app.ui = ui.sanitized();
            vectorcraft_ui_egui::prefs_dialog::restore(app);
        }
        Err(e) => note(&format!("preferences could not be read: {e}")),
    }
}

fn save_prefs(app: &VectorcraftApp) {
    let Some(dir) = config_dir() else { return };
    let _ = std::fs::create_dir_all(&dir);
    let mut ui = app.ui.clone();
    // An open dialog is never restored, and its fields can hold passwords.
    ui.dialog = None;
    ui.engine_prefs = app.session.prefs.to_json();
    let Ok(bytes) = serde_json::to_vec_pretty(&ui) else { return };
    let tmp = dir.join("ui.json.tmp");
    if std::fs::write(&tmp, bytes).is_ok() {
        let _ = std::fs::rename(&tmp, dir.join("ui.json"));
    }
}

fn dir_string(name: &str) -> Option<String> {
    let dir = config_dir()?.join(name);
    let _ = std::fs::create_dir_all(&dir);
    Some(dir.to_string_lossy().into_owned())
}

// ---------------------------------------------------------------------------------------------
// Services: what the app asks the iPad to do
// ---------------------------------------------------------------------------------------------

struct IosPrint {
    cb: VCCallbacks,
}

// The callbacks are only ever used on the main thread, from the app's own frame.
unsafe impl Send for IosPrint {}

impl PrintService for IosPrint {
    fn printers(&mut self) -> Vec<Printer> {
        // iPadOS has no printer list for apps: its print sheet picks the printer.
        vec![]
    }

    fn print(&mut self, job: &PrintJob) -> Result<String, String> {
        let Some(f) = self.cb.print_pdf else { return Err("printing is not available".to_string()) };
        let title = cstring(&job.title.to_string());
        unsafe { f(self.cb.user, title.as_ptr(), job.pdf.as_ptr(), job.pdf.len()) };
        Ok(format!("Printing “{}”: pick the printer in the print sheet", job.title))
    }
}

fn build_services(cb: VCCallbacks, picked: &PickedInbox, dropped: &Inbox, place: &PlaceInbox, stylus: StylusFeed) -> Services {
    Services {
        // File › Open…: Apple's Files picker; the answer (or None when cancelled) arrives in `picked`.
        open_async: Some(Box::new(move || {
            note("the app asked to open a file");
            if let Some(f) = cb.open_files {
                unsafe { f(cb.user) }
            }
        })),
        // File › Place…: the picked files arrive in `place`.
        place_async: Some(Box::new(move || {
            note("the app asked to place files");
            if let Some(f) = cb.place_files {
                unsafe { f(cb.user) }
            }
        })),
        // Save, Save As and exports: Apple's Save to Files sheet.
        download: Some(Box::new(move |name: &str, bytes: &[u8]| -> Result<(), String> {
            note(&format!("save requested: {name}, {} bytes", bytes.len()));
            let Some(f) = cb.save_file else { return Err("saving is not available".to_string()) };
            let n = cstring(name);
            unsafe { f(cb.user, n.as_ptr(), bytes.as_ptr(), bytes.len()) };
            Ok(())
        })),
        inbox: Some(dropped.clone()),
        picked_inbox: Some(picked.clone()),
        place_inbox: Some(place.clone()),
        open_url: Some(Box::new(move |url: &str| {
            if let Some(f) = cb.open_url {
                let c = cstring(url);
                unsafe { f(cb.user, c.as_ptr()) }
            }
        })),
        print: Some(Box::new(IosPrint { cb })),
        // Apple Pencil pressure, tilt and the eraser, for the canvas.
        stylus: Some(stylus),
        ..Default::default()
    }
}

// ---------------------------------------------------------------------------------------------
// Graphics (Metal through wgpu)
// ---------------------------------------------------------------------------------------------

struct Gpu {
    surface: wgpu::Surface<'static>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    renderer: egui_wgpu::Renderer,
    config: wgpu::SurfaceConfiguration,
    needs_reconfigure: bool,
}

impl Gpu {
    fn new(layer: *mut c_void, width: u32, height: u32) -> Result<Gpu, String> {
        let instance = wgpu::Instance::default();
        let surface: wgpu::Surface<'static> =
            unsafe { instance.create_surface_unsafe(wgpu::SurfaceTargetUnsafe::CoreAnimationLayer(layer)) }
                .map_err(|e| format!("surface: {e}"))?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        }))
        .map_err(|e| format!("adapter: {e}"))?;
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("vectorcraft"),
            required_limits: wgpu::Limits { max_texture_dimension_2d: 8192, ..wgpu::Limits::default() },
            ..Default::default()
        }))
        .map_err(|e| format!("device: {e}"))?;
        let caps = surface.get_capabilities(&adapter);
        let format = egui_wgpu::preferred_framebuffer_format(&caps.formats).map_err(|e| format!("format: {e}"))?;
        let mut config = surface
            .get_default_config(&adapter, width.max(1), height.max(1))
            .ok_or_else(|| "this surface is not supported".to_string())?;
        config.format = format;
        config.view_formats = vec![format];
        config.present_mode = wgpu::PresentMode::AutoVsync;
        surface.configure(&device, &config);
        let renderer = egui_wgpu::Renderer::new(&device, format, egui_wgpu::RendererOptions::default());
        Ok(Gpu { surface, device, queue, renderer, config, needs_reconfigure: false })
    }
}

// ---------------------------------------------------------------------------------------------
// The host: one per window
// ---------------------------------------------------------------------------------------------

/// The pen's touch device (fingers use another, so egui doesn't pinch a pen with a finger).
const PEN_DEVICE: TouchDeviceId = TouchDeviceId(1);
const FINGER_DEVICE: TouchDeviceId = TouchDeviceId(2);

struct Host {
    app: VectorcraftApp,
    ctx: egui::Context,
    gpu: Gpu,
    scale: f32,
    events: Vec<egui::Event>,
    modifiers: egui::Modifiers,
    dark: bool,
    focused: bool,
    start: Instant,
    deadline: Arc<Mutex<Option<Instant>>>,
    cb: VCCallbacks,
    picked: PickedInbox,
    dropped: Inbox,
    place: PlaceInbox,
    stylus: StylusFeed,
    /// The pen pressing, by touch id.
    pen: Option<i32>,
    /// The fingers down, by touch id.
    fingers: Vec<i32>,
    /// The contact driving egui's pointer.
    primary: Option<i32>,
    primary_button: Option<PointerButton>,
    /// The pen is turned to its eraser (Apple Pencil double tap or squeeze).
    eraser: bool,
    wants_keyboard: bool,
}

fn wake_at(deadline: &Arc<Mutex<Option<Instant>>>, at: Instant) {
    let mut d = deadline.lock().unwrap_or_else(|e| e.into_inner());
    if d.is_none_or(|cur| at < cur) {
        *d = Some(at);
    }
}

impl Host {
    fn new(layer: *mut c_void, width: u32, height: u32, scale: f32, cb: VCCallbacks) -> Result<Host, String> {
        // Folders that show up in Files > On My iPad > VectorCraft.
        if let Some(docs) = documents_dir() {
            let fonts = docs.join("Fonts");
            let _ = std::fs::create_dir_all(&fonts);
            // The app's own Fonts folder is scanned with the iPad's fonts.
            vectorcraft_text::set_app_font_dir(fonts);
        }

        let gpu = Gpu::new(layer, width, height)?;
        let ctx = egui::Context::default();
        // Apple's shortcut set only: the app asks the context which system it runs on.
        ctx.set_os(egui::os::OperatingSystem::Mac);
        VectorcraftApp::install_ime_reset_hooks(&ctx);
        let deadline: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(Some(Instant::now())));
        {
            let dl = deadline.clone();
            ctx.set_request_repaint_callback(move |info| {
                let now = Instant::now();
                let at = now.checked_add(info.delay).unwrap_or(now + Duration::from_secs(3600));
                wake_at(&dl, at);
            });
        }

        let picked = PickedInbox::default();
        let dropped = Inbox::default();
        let place = PlaceInbox::default();
        let stylus = StylusFeed::on_ui_thread();
        let services = build_services(cb, &picked, &dropped, &place, stylus.clone());

        let mut app = VectorcraftApp::new(Session::new(), services);
        load_prefs(&mut app);

        // What the user keeps lives next to the preferences, as on the desktop.
        app.session.swatch_libraries.set_user_dir(dir_string("Swatches"));
        app.session.style_libraries.set_user_dir(dir_string("Graphic Styles"));
        app.session.symbol_libraries.set_user_dir(dir_string("Symbols"));
        app.session.brush_libraries.set_user_dir(dir_string("Brushes"));
        vectorcraft_ui_egui::panels::library_panel::restore(&mut app);
        app.session.libraries.set_dir(dir_string("Libraries"));
        // Data Recovery copies: the automatic saves of unsaved work.
        app.session.recovery.set_default_folder(dir_string("Data Recovery"));

        Ok(Host {
            app,
            ctx,
            gpu,
            scale,
            events: Vec::new(),
            modifiers: egui::Modifiers::NONE,
            dark: false,
            focused: true,
            start: Instant::now(),
            deadline,
            cb,
            picked,
            dropped,
            place,
            stylus,
            pen: None,
            fingers: Vec::new(),
            primary: None,
            primary_button: None,
            eraser: false,
            wants_keyboard: false,
        })
    }

    fn wake(&self) {
        wake_at(&self.deadline, Instant::now());
    }

    fn push(&mut self, e: egui::Event) {
        self.events.push(e);
        self.wake();
    }

    /// Tells egui which modifier keys (Shift, Command, ...) are down, whenever that changes.
    /// This egui version learns modifier state only from this event.
    fn set_modifiers(&mut self, m: egui::Modifiers) {
        if m != self.modifiers {
            self.modifiers = m;
            self.push(Event::ModifiersChanged(m));
        }
    }

    /// Points in the UIKit sense, converted to egui points (the interface scaling zooms).
    fn pt(&self, x: f32, y: f32) -> Pos2 {
        let z = self.ctx.zoom_factor().max(0.1);
        egui::pos2(x / z, y / z)
    }

    // --- pen and finger contacts (the model of the web build's pen and touch code) -------------

    fn push_touch(&mut self, device: TouchDeviceId, id: i32, phase: TouchPhase, pos: Pos2, force: Option<f32>) {
        self.push(Event::Touch { device_id: device, id: TouchId::from(id as u64), phase, pos, force });
    }

    fn press(&mut self, id: i32, pos: Pos2, button: PointerButton, mods: egui::Modifiers) {
        self.primary = Some(id);
        self.primary_button = Some(button);
        self.push(Event::ModifiersChanged(mods));
        self.modifiers = mods;
        self.push(Event::PointerMoved(pos));
        self.push(Event::PointerButton { pos, button, pressed: true, modifiers: mods });
    }

    fn release(&mut self, pos: Pos2, mods: egui::Modifiers) {
        self.primary = None;
        if let Some(button) = self.primary_button.take() {
            self.push(Event::ModifiersChanged(mods));
            self.modifiers = mods;
            self.push(Event::PointerButton { pos, button, pressed: false, modifiers: mods });
        }
    }

    /// Cancel every finger down (a palm under a pen landing).
    fn cancel_fingers(&mut self, pos: Pos2, mods: egui::Modifiers) {
        for id in std::mem::take(&mut self.fingers) {
            self.push_touch(FINGER_DEVICE, id, TouchPhase::Cancel, pos, None);
            if self.primary == Some(id) {
                self.release(pos, mods);
                self.push(Event::PointerGone);
            }
        }
    }

    fn pen_sample(&self, pressure: f32, pose: PenPose) {
        self.stylus.set_sample(Some(PenSample { pressure, eraser: self.eraser, pose }));
    }

    #[allow(clippy::too_many_arguments)]
    fn touch_input(&mut self, kind: c_int, id: i32, phase: c_int, pos: Pos2, pressure: f32, mods: egui::Modifiers, pose: PenPose) {
        let phase = match phase {
            0 => TouchPhase::Start,
            1 => TouchPhase::Move,
            2 => TouchPhase::End,
            _ => TouchPhase::Cancel,
        };
        if kind == 1 {
            // Apple Pencil.
            let force = Some(pressure.clamp(0.0, 1.0));
            match phase {
                TouchPhase::Start => {
                    touch::set_source(Source::Pen);
                    self.cancel_fingers(pos, mods);
                    self.pen_sample(pressure, pose);
                    self.pen = Some(id);
                    self.push_touch(PEN_DEVICE, id, TouchPhase::Start, pos, force);
                    self.press(id, pos, PointerButton::Primary, mods);
                }
                TouchPhase::Move if self.pen == Some(id) => {
                    self.pen_sample(pressure, pose);
                    self.push_touch(PEN_DEVICE, id, TouchPhase::Move, pos, force);
                    self.push(Event::PointerMoved(pos));
                }
                TouchPhase::End | TouchPhase::Cancel if self.pen == Some(id) => {
                    self.pen_sample(0.0, PenPose::default());
                    self.pen = None;
                    self.push_touch(PEN_DEVICE, id, phase, pos, None);
                    self.release(pos, mods);
                }
                _ => {}
            }
        } else {
            // A finger. While the pen presses, fingers are ignored (palm rejection).
            match phase {
                TouchPhase::Start => {
                    if self.pen.is_some() {
                        return;
                    }
                    self.fingers.push(id);
                    self.push_touch(FINGER_DEVICE, id, TouchPhase::Start, pos, None);
                    if self.primary.is_none() && self.fingers.len() == 1 {
                        touch::set_source(Source::Finger);
                        self.stylus.set(None);
                        self.press(id, pos, PointerButton::Primary, mods);
                    }
                }
                TouchPhase::Move if self.fingers.contains(&id) => {
                    self.push_touch(FINGER_DEVICE, id, TouchPhase::Move, pos, None);
                    if self.primary == Some(id) {
                        self.push(Event::PointerMoved(pos));
                    }
                }
                TouchPhase::End | TouchPhase::Cancel if self.fingers.contains(&id) => {
                    self.fingers.retain(|f| *f != id);
                    self.push_touch(FINGER_DEVICE, id, phase, pos, None);
                    if self.primary == Some(id) {
                        self.release(pos, mods);
                        self.push(Event::PointerGone);
                    }
                }
                _ => {}
            }
        }
    }

    fn handle_output(&self, out: &egui::PlatformOutput) {
        for cmd in &out.commands {
            match cmd {
                egui::OutputCommand::CopyText(text) => {
                    if let Some(f) = self.cb.copy_text {
                        let c = cstring(text);
                        unsafe { f(self.cb.user, c.as_ptr()) }
                    }
                }
                egui::OutputCommand::OpenUrl(open) => {
                    if let Some(f) = self.cb.open_url {
                        let c = cstring(&open.url);
                        unsafe { f(self.cb.user, c.as_ptr()) }
                    }
                }
                _ => {}
            }
        }
    }

    fn flags(&self, drew: bool) -> c_int {
        (drew as c_int) | ((self.wants_keyboard as c_int) << 1)
    }

    fn frame(&mut self) -> c_int {
        let now = Instant::now();
        let due = self.deadline.lock().unwrap_or_else(|e| e.into_inner()).is_some_and(|t| now >= t);
        if !due {
            return self.flags(false);
        }
        *self.deadline.lock().unwrap_or_else(|e| e.into_inner()) = None;

        let ppp = self.scale * self.ctx.zoom_factor().max(0.1);
        let rect = egui::Rect::from_min_size(
            Pos2::ZERO,
            egui::vec2(self.gpu.config.width as f32 / ppp, self.gpu.config.height as f32 / ppp),
        );
        let mut raw = egui::RawInput::default();
        raw.time = Some(self.start.elapsed().as_secs_f64());
        raw.screen_rect = Some(rect);
        raw.focused = self.focused;
        raw.system_theme = Some(if self.dark { egui::Theme::Dark } else { egui::Theme::Light });
        raw.max_texture_side = Some(self.gpu.device.limits().max_texture_dimension_2d as usize);
        raw.events = std::mem::take(&mut self.events);
        if let Some(v) = raw.viewports.get_mut(&egui::ViewportId::ROOT) {
            v.native_pixels_per_point = Some(self.scale);
            v.inner_rect = Some(rect);
        }

        let ctx = self.ctx.clone();
        self.app.raw_input_hook(&ctx, &mut raw);
        let logic = ctx.run_logic(&raw, |c| self.app.logic(c));
        let mut full = ctx.run_ui(raw, |ui| self.app.ui(ui));
        self.handle_output(&logic.platform_output);
        self.handle_output(&full.platform_output);
        self.wants_keyboard = ctx.egui_wants_keyboard_input();

        if let Some(vo) = full.viewport_output.get(&egui::ViewportId::ROOT)
            && let Some(at) = Instant::now().checked_add(vo.repaint_delay)
        {
            wake_at(&self.deadline, at);
        }

        let ppp_out = full.pixels_per_point;
        let shapes = std::mem::take(&mut full.shapes);
        let prims = ctx.tessellate(shapes, ppp_out);

        let deadline = self.deadline.clone();
        let gpu = &mut self.gpu;
        for (id, deltas) in full.textures_delta.set.drain() {
            for d in deltas {
                gpu.renderer.update_texture(&gpu.device, &gpu.queue, id, &d);
            }
        }

        if gpu.needs_reconfigure {
            gpu.surface.configure(&gpu.device, &gpu.config);
            gpu.needs_reconfigure = false;
        }
        let frame = if prims.is_empty() {
            // The app skips painting for a frame now and then (while it switches fonts). Showing
            // that empty frame would flash a blank screen, so the picture on screen is kept.
            None
        } else {
            match gpu.surface.get_current_texture() {
                wgpu::CurrentSurfaceTexture::Success(f) => Some(f),
                wgpu::CurrentSurfaceTexture::Suboptimal(f) => {
                    gpu.needs_reconfigure = true;
                    Some(f)
                }
                _ => {
                    gpu.surface.configure(&gpu.device, &gpu.config);
                    wake_at(&deadline, Instant::now());
                    None
                }
            }
        };

        if let Some(frame) = frame {
            let view = frame.texture.create_view(&wgpu::TextureViewDescriptor::default());
            let mut encoder = gpu
                .device
                .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: Some("vectorcraft") });
            let screen = egui_wgpu::ScreenDescriptor {
                size_in_pixels: [gpu.config.width, gpu.config.height],
                pixels_per_point: ppp_out,
            };
            let extra = gpu.renderer.update_buffers(&gpu.device, &gpu.queue, &mut encoder, &prims, &screen);
            {
                let pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("vectorcraft"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &view,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color { r: 0.11, g: 0.11, b: 0.12, a: 1.0 }),
                            store: wgpu::StoreOp::Store,
                        },
                        depth_slice: None,
                    })],
                    depth_stencil_attachment: None,
                    timestamp_writes: None,
                    occlusion_query_set: None,
                    multiview_mask: None,
                });
                gpu.renderer.render(&mut pass.forget_lifetime(), &prims, &screen);
            }
            gpu.queue.submit(extra.into_iter().chain(std::iter::once(encoder.finish())));
            gpu.queue.present(frame);
        }

        for id in full.textures_delta.free.drain() {
            gpu.renderer.free_texture(&id);
        }
        self.flags(true)
    }
}

// ---------------------------------------------------------------------------------------------
// The C interface Swift calls
// ---------------------------------------------------------------------------------------------

unsafe fn host<'a>(h: *mut c_void) -> Option<&'a mut Host> {
    unsafe { (h as *mut Host).as_mut() }
}

static HOOK: Once = Once::new();

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_create(layer: *mut c_void, width_px: u32, height_px: u32, scale: f32, cb: VCCallbacks) -> *mut c_void {
    HOOK.call_once(|| {
        std::panic::set_hook(Box::new(|info| {
            note(&format!("PANIC: {info}\n{}", std::backtrace::Backtrace::force_capture()));
        }));
    });
    guard(std::ptr::null_mut(), || match Host::new(layer, width_px, height_px, scale, cb) {
        Ok(h) => Box::into_raw(Box::new(h)) as *mut c_void,
        Err(e) => {
            note(&format!("start failed: {e}"));
            std::ptr::null_mut()
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_destroy(h: *mut c_void) {
    if !h.is_null() {
        guard((), || drop(unsafe { Box::from_raw(h as *mut Host) }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_resize(h: *mut c_void, width_px: u32, height_px: u32, scale: f32) {
    guard((), || {
        if let Some(h) = unsafe { host(h) } {
            h.scale = scale;
            h.gpu.config.width = width_px.max(1);
            h.gpu.config.height = height_px.max(1);
            h.gpu.surface.configure(&h.gpu.device, &h.gpu.config);
            h.wake();
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_set_dark(h: *mut c_void, dark: c_int) {
    if let Some(h) = unsafe { host(h) } {
        h.dark = dark != 0;
        h.wake();
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_set_focused(h: *mut c_void, focused: c_int) {
    if let Some(h) = unsafe { host(h) } {
        h.focused = focused != 0;
        h.wake();
    }
}

/// An Apple Pencil was used on this iPad before: fingers only navigate from the start.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_set_pen_seen(_h: *mut c_void, seen: c_int) {
    touch::set_pen_seen(seen != 0);
}

/// Apple Pencil double tap or squeeze: turn the pen to its eraser, and back.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_toggle_eraser(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.eraser = !h.eraser;
        h.pen_sample(0.0, PenPose::default());
        h.wake();
    }
}

// --- mouse and trackpad ---------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_pointer_moved(h: *mut c_void, x: f32, y: f32, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        if h.primary.is_none() {
            h.stylus.set(None);
        }
        h.set_modifiers(to_mods(mods));
        let p = h.pt(x, y);
        h.push(Event::PointerMoved(p));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_pointer_gone(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.push(Event::PointerGone);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_pointer_button(h: *mut c_void, x: f32, y: f32, button: c_int, pressed: c_int, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        if pressed != 0 {
            touch::set_source(Source::Mouse);
            h.stylus.set(None);
        }
        h.set_modifiers(to_mods(mods));
        let pos = h.pt(x, y);
        let button = match button {
            1 => PointerButton::Secondary,
            2 => PointerButton::Middle,
            _ => PointerButton::Primary,
        };
        let m = h.modifiers;
        h.push(Event::PointerMoved(pos));
        h.push(Event::PointerButton { pos, button, pressed: pressed != 0, modifiers: m });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_scroll(h: *mut c_void, dx: f32, dy: f32, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        h.set_modifiers(to_mods(mods));
        let z = h.ctx.zoom_factor().max(0.1);
        let m = h.modifiers;
        h.push(Event::MouseWheel {
            unit: egui::MouseWheelUnit::Point,
            delta: egui::vec2(dx / z, dy / z),
            phase: TouchPhase::Move,
            source: egui::MouseWheelSource::Unknown,
            modifiers: m,
        });
    }
}

/// A trackpad pinch (finger pinches reach the app as touches).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_pinch(h: *mut c_void, factor: f32) {
    if let Some(h) = unsafe { host(h) } {
        if factor.is_finite() && factor > 0.0 {
            h.push(Event::Zoom(factor));
        }
    }
}

// --- fingers and Apple Pencil ---------------------------------------------------------------

/// One contact. `kind`: 0 finger, 1 Apple Pencil. `phase`: 0 start, 1 move, 2 end, 3 cancel.
/// `pressure`: 0..1. `tilt_x`, `tilt_y` (degrees) and `roll` (degrees): NaN when not known.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_touch(
    h: *mut c_void,
    kind: c_int,
    id: i32,
    phase: c_int,
    x: f32,
    y: f32,
    pressure: f32,
    mods: u32,
    tilt_x: f32,
    tilt_y: f32,
    roll: f32,
) {
    if let Some(h) = unsafe { host(h) } {
        let pos = h.pt(x, y);
        let pose = PenPose {
            tilt: (tilt_x.is_finite() && tilt_y.is_finite()).then(|| [tilt_x, tilt_y]),
            rotation: roll.is_finite().then_some(roll),
        };
        h.touch_input(kind, id, phase, pos, pressure, to_mods(mods), pose);
    }
}

// --- keyboard and clipboard -----------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_key(h: *mut c_void, hid: u32, pressed: c_int, repeat: c_int, mods: u32) {
    if let Some(h) = unsafe { host(h) } {
        h.set_modifiers(to_mods(mods));
        let Some(key) = hid_to_key(hid) else { return };
        let m = h.modifiers;
        h.push(Event::Key { key, physical_key: Some(key), pressed: pressed != 0, repeat: repeat != 0, modifiers: m });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_text(h: *mut c_void, utf8: *const c_char) {
    if let Some(h) = unsafe { host(h) }
        && let Some(s) = unsafe { from_c(utf8) }
        && !s.is_empty()
    {
        h.push(Event::Text(s));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_copy(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.push(Event::Copy);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_cut(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.push(Event::Cut);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_paste(h: *mut c_void, utf8: *const c_char) {
    if let Some(h) = unsafe { host(h) }
        && let Some(s) = unsafe { from_c(utf8) }
    {
        h.push(Event::Paste(s));
    }
}

// --- files ------------------------------------------------------------------------------------

/// The file the person picked for File › Open.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_open_file(h: *mut c_void, name: *const c_char, data: *const u8, len: usize) {
    if let Some(h) = unsafe { host(h) }
        && let Some(name) = unsafe { from_c(name) }
    {
        note(&format!("a file arrived to open: {name}, {len} bytes"));
        let bytes = unsafe { bytes_from(data, len) };
        h.picked.lock().unwrap_or_else(|e| e.into_inner()).push(Some((name, bytes)));
        h.wake();
    }
}

/// The open picker was cancelled (the app waits for an answer either way).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_open_cancel(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        h.picked.lock().unwrap_or_else(|e| e.into_inner()).push(None);
        h.wake();
    }
}

/// A file the person picked for File › Place.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_place_file(h: *mut c_void, name: *const c_char, data: *const u8, len: usize) {
    if let Some(h) = unsafe { host(h) }
        && let Some(name) = unsafe { from_c(name) }
    {
        let bytes = unsafe { bytes_from(data, len) };
        h.place.lock().unwrap_or_else(|e| e.into_inner()).push(PlaceArrival { name, bytes, drop: None });
        h.wake();
    }
}

/// A file handed to the app from outside (Open in VectorCraft from Files or another app).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_drop_file(h: *mut c_void, name: *const c_char, data: *const u8, len: usize) {
    if let Some(h) = unsafe { host(h) }
        && let Some(name) = unsafe { from_c(name) }
    {
        note(&format!("a file was handed over: {name}, {len} bytes"));
        let bytes = unsafe { bytes_from(data, len) };
        h.dropped.lock().unwrap_or_else(|e| e.into_inner()).push((name, bytes));
        h.wake();
    }
}

// --- frames and state -------------------------------------------------------------------------

/// Called every display refresh. Bit 0: a frame was drawn. Bit 1: the on-screen keyboard is wanted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_frame(h: *mut c_void) -> c_int {
    guard(0, || match unsafe { host(h) } {
        Some(h) => h.frame(),
        None => 0,
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn vc_save_state(h: *mut c_void) {
    if let Some(h) = unsafe { host(h) } {
        guard((), || save_prefs(&h.app));
    }
}
