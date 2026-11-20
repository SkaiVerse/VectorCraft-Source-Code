#!/usr/bin/env python3
"""Changes made to VectorCraft's own source on the build machine only (nothing is committed).

Run from the repository root. Each change prints how many places it matched: it must be 1. A 0
means the upstream code changed and that feature will not work until the change is updated.
The report is written to logs/patch-result.txt.
"""
import json
import pathlib
import re
import textwrap

report = []


def patch(path, pairs):
    p = pathlib.Path(path)
    if not p.exists():
        report.append(f"{path}: FILE NOT FOUND")
        return
    s = p.read_text()
    for old, new in pairs:
        count = s.count(old)
        report.append(f"{path}: {count} match(es) of {old[:70]!r}")
        s = s.replace(old, new)
    p.write_text(s)


MAC = 'cfg!(target_os = "macos")'
APPLE = 'cfg!(any(target_os = "macos", target_os = "ios"))'

# ---- Shortcuts: Apple's set (Command), never the Windows/Linux one -----------------------------
patch("crates/ui-egui/src/keymap.rs", [
    ("web.unwrap_or_else(Platform::current)",
     'web.unwrap_or_else(|| if cfg!(target_os = "ios") { Platform::Mac } else { Platform::current() })'),
])

# ---- Menus show the symbols for Command, Shift and Option --------------------------------------
patch("crates/ui-egui/src/menus/entries.rs", [
    ("    if " + MAC + " {\n        let mut mods = String::new();",
     "    if " + APPLE + " {\n        let mut mods = String::new();"),
])
patch("crates/ui-egui/src/shortcut_editor.rs", [
    ("if m.ctrl && (" + MAC + " || !m.command) {",
     "if m.ctrl && (" + APPLE + " || !m.command) {"),
])

# ---- Fonts: the iPad keeps Apple's fonts in /System/Library/Fonts, as macOS does ---------------
patch("crates/text/src/fontdb/dirs.rs", [
    ("if " + MAC + ' {\n        dirs.extend(["/System/Library/Fonts"',
     "if " + APPLE + ' {\n        dirs.extend(["/System/Library/Fonts"'),
])

# ---- Touch Space replaces the built-in Touch workspace -----------------------------------------
patch("crates/ui-egui/src/workspaces.rs", [
    ('        w(TOUCH, &|x| {\n'
     '            x.control_bar = true;\n'
     '            x.toolbar = true;\n'
     '            x.toolbar_advanced = true;\n'
     '            x.task_bar = true;\n'
     '            x.open_panel = Some("align".into());\n'
     '        }),\n',
     '        w("Touch Space", &|x| {\n'
     '            x.toolbar = true;\n'
     '            x.toolbar_advanced = true;\n'
     '            x.dock_collapsed = true;\n'
     '            x.open_panel = None;\n'
     '        }),\n'),
])

# ---- The app draws its own tool cursors (as on macOS) ------------------------------------------
patch("crates/ui-egui/src/cursors.rs", [
    ('pub const OS_CURSORS: bool = !cfg!(any(target_os = "macos", target_arch = "wasm32"));',
     'pub const OS_CURSORS: bool = !cfg!(any(target_os = "macos", target_os = "ios", target_arch = "wasm32"));'),
])

# ---- Toolbar -------------------------------------------------------------------------------------
# * The controls under the tools (colours, screen mode, draw modes) and Undo, Redo and Delete stay
#   fixed at the bottom while the tools scroll.
ui_src = "".join(f.read_text() for f in pathlib.Path("crates/ui-egui/src").rglob("*.rs"))


def icon(cands, last):
    for c in cands:
        if '"' + c + '"' in ui_src and pathlib.Path("assets/icons/" + c + ".svg").exists():
            return c
    for c in cands:
        if pathlib.Path("assets/icons/" + c + ".svg").exists():
            return c
    return last


undo_i = icon(["undo-2", "undo", "rotate-ccw"], "ellipsis")
redo_i = icon(["redo-2", "redo", "rotate-cw"], "ellipsis")
trash_i = icon(["trash-2", "trash", "delete"], "ellipsis")
report.append(f"toolbar icons: {undo_i} {redo_i} {trash_i}")

touch_fn = textwrap.dedent('''
    /// Undo, Redo and Delete: a section of their own at the bottom of the toolbar (as Affinity's
    /// has them), for a finger or the pencil.
    fn touch_actions(app: &mut VectorcraftApp, ui: &mut Ui, t: &Tokens) {
        ui.add_space(6.0);
        let (r, _) = ui.allocate_exact_size(vec2(ui.available_width(), 1.0), Sense::hover());
        ui.painter().line_segment([r.left_center() + vec2(6.0, 0.0), r.right_center() - vec2(6.0, 0.0)], Stroke::new(1.0, t.text_disabled));
        ui.add_space(6.0);
        ui.vertical_centered(|ui| {
            if widgets::icon_button(ui, "@UNDO@", "Undo", false, 30.0).clicked() {
                app.run("edit.undo", json!({})).ok();
            }
            if widgets::icon_button(ui, "@REDO@", "Redo", false, 30.0).clicked() {
                app.run("edit.redo", json!({})).ok();
            }
            if widgets::icon_button(ui, "@TRASH@", "Delete", false, 30.0).clicked() {
                // The Delete key itself, so the tool in use deletes what it would on a keyboard
                // (a Puppet Warp pin, an anchor point), not the whole object.
                ui.ctx().data_mut(|d| d.insert_temp(egui::Id::new("vc-synth-delete"), true));
                ui.ctx().request_repaint();
            }
        });
        ui.add_space(10.0);
    }
''').replace("@UNDO@", undo_i).replace("@REDO@", redo_i).replace("@TRASH@", trash_i)

patch("crates/ui-egui/src/toolbar.rs", [
    # The scrolling tools leave room for the fixed section below them.
    ('    widgets::strip_scroll(ui, "toolbar", |ui| {',
     '    let fixed_id = egui::Id::new("vc-toolbar-fixed-height");\n'
     '    let fixed_h: f32 = ui.ctx().data(|d| d.get_temp(fixed_id)).unwrap_or(200.0);\n'
     '    ui.scope(|ui| {\n'
     '    ui.set_max_height((ui.available_height() - fixed_h).max(90.0));\n'
     '    widgets::strip_scroll(ui, "toolbar", |ui| {'),
    ("        ui.add_space(8.0);\n        bottom_controls(app, ui, &t, cols);\n    });",
     "        ui.add_space(8.0);\n    });\n    });\n"
     "    // The fixed section: a divider, then colours, screen mode, draw modes, then Undo, Redo and Delete.\n"
     "    let fixed_top = ui.cursor().top();\n"
     "    ui.add_space(4.0);\n"
     "    let (divider, _) = ui.allocate_exact_size(vec2(ui.available_width(), 1.0), Sense::hover());\n"
     "    ui.painter().line_segment([divider.left_center() + vec2(6.0, 0.0), divider.right_center() - vec2(6.0, 0.0)], Stroke::new(1.0, t.text_disabled));\n"
     "    ui.add_space(6.0);\n"
     "    bottom_controls(app, ui, &t, cols);\n"
     "    touch_actions(app, ui, &t);\n"
     "    let measured = ui.cursor().top() - fixed_top;\n"
     "    ui.ctx().data_mut(|d| d.insert_temp(fixed_id, measured + 6.0));"),
])
tb = pathlib.Path("crates/ui-egui/src/toolbar.rs")
if tb.exists():
    tb.write_text(tb.read_text() + "\n" + touch_fn)

# ---- The Apple Pencil's arc menu uses the software's own tool icons ----------------------------
catalog = pathlib.Path("crates/tools/src/catalog.rs")
assets = pathlib.Path("ios/App/Assets.xcassets")
assets.mkdir(parents=True, exist_ok=True)
if catalog.exists():
    text = catalog.read_text()
    for tid in ["selection", "pen", "shapeBuilder", "type", "directSelection", "eyedropper", "eraser", "pencil"]:
        m = re.search(r't\("%s",\s*"[^"]*",\s*(?:Some\("[^"]*"\)|None),\s*"([^"]+)"\)' % re.escape(tid), text)
        if not m:
            report.append(f"arc icon {tid}: tool not found in the catalogue")
            continue
        name = m.group(1)
        src = pathlib.Path("assets/icons") / (name + ".svg")
        if not src.exists():
            report.append(f"arc icon {tid}: {src} not found")
            continue
        d = assets / f"arc-{tid}.imageset"
        d.mkdir(parents=True, exist_ok=True)
        # The tint replaces the colour, so the strokes only have to be opaque.
        (d / (name + ".svg")).write_text(src.read_text().replace("currentColor", "#000000"))
        (d / "Contents.json").write_text(json.dumps({
            "images": [{"filename": name + ".svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
        }))
        report.append(f"arc icon {tid}: {name}.svg")
else:
    report.append("arc icons: catalogue not found")

pathlib.Path("logs").mkdir(exist_ok=True)
pathlib.Path("logs/patch-result.txt").write_text("\n".join(report) + "\n")
print("\n".join(report))
