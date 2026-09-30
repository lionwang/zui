# zui

A declarative, Skia-based UI library for [Zig](https://ziglang.org), written in
the spirit of [Freya](https://github.com/marc2332/freya).

Freya's Rust stack maps onto zui roughly like this:

| Freya            | zui                                   |
|------------------|---------------------------------------|
| dioxus (VDOM)    | `element` + `reconcile`               |
| hooks / signals  | `context.Context` (`useState`, ...)   |
| Skia             | `skia` (Zig bindings over `zsk`, a C ABI on Skia) |
| taffy (flexbox)  | `layout`                              |
| winit            | `window` (GLFW 3.4, compiled from source) |
| the renderer     | `paint`                               |
| the event loop   | `app`                                 |

Windows only for now (the Skia binaries are built for the MSVC ABI and the
window layer uses the Win32/GLFW backend).

![zui counter](screenshot.png)

The counter example, captured by `zig build check`: it drives the UI
programmatically (hover, click, live resize), reads the framebuffer back and
writes `screenshot.png`.

## Building blocks

```
src/
  zsk.h / zsk.cpp        thin C ABI over the parts of Skia that zui uses,
                         compiled with MSVC's cl.exe (Skia is C++ and its
                         prebuilt libraries use the MSVC ABI and the dynamic
                         runtime, so it cannot be compiled by Zig's clang)
  zui/
    zui.zig              library root; `zui.launch(Root, props)` entry point
    element.zig          the virtual DOM: `Element` (rect/text/image/component/
                         none), `Style` (flexbox subset + text + paint), handlers
    context.zig          `Context`: React-style hooks (`useState`, `useSignal`,
                         `useMemo`), component constructors, `State(T)`
    signal.zig           `Signal(T)` reactive value
    node.zig             retained tree: hooks, cached Skia paragraphs/images,
                         layout box
    reconcile.zig        diffing (kind + key matching) of the fresh element tree
                         against the retained node tree
    layout/layout.zig    flexbox: column/row, gap, padding/margin/border,
                         grow/shrink/basis, min/max, align, justify, no wrap
    paint.zig            rounded rects, per-edge borders, text paragraphs,
                         images, overflow clipping
    window.zig           GLFW window + event callbacks + cursor management
    app.zig              the frame loop: poll -> build vdom (frame arena) ->
                         reconcile -> layout -> hit test / dispatch -> paint
    widgets/widgets.zig  `ui.rect/column/row/spacer/text/textFmt/button/image`
    tests.zig            unit tests (no window, no GPU)
examples/
  counter/               reactive counter, mirroring Freya's intro example
  check/                 headless render check: drives the UI programmatically
                         (hover, click, live resize), reads the framebuffer
                         back and writes screenshot.png
```

## Requirements

* **Zig 0.16.0**
* **Visual Studio 2022** (for `cl.exe`) and the Windows SDK (for `ucrt.lib` and
  `uuid.lib`)
* **Vendored Skia**: static MSVC-ABI libraries in `vendor/skia-binaries/`
  (`skia.lib`, `skparagraph.lib`, `skshaper.lib`, `skunicode_core.lib`,
  `skunicode_icu.lib`, `icudtl.dat`) with headers under `vendor/skia/`
  (`vendor/skia/` holds only the ~130 headers reachable from `zsk.cpp`,
  about 1.3 MB, not the whole Skia source tree; the Skia license lives in
  `vendor/skia-binaries/LICENSE_SKIA`)
* **Vendored GLFW 3.4** source in `vendor/glfw/` (compiled from source by
  the build script)

`build.zig` finds the MSVC and Windows SDK library directories itself; it
compiles `src/zsk.cpp` through `.compile_cl.bat` (a wrapper that calls the
VS 2022 developer environment), compiles the win32 GLFW sources with Zig's
own clang, links everything into one executable and installs `icudtl.dat`
next to it.

## Usage

A zui app is a component: a struct with `pub fn render(ctx: *Context, props:
Props) Element`. State lives in hooks on the retained node, so it survives
across frames.

```zig
const std = @import("std");
const zui = @import("zui");
const ui = zui.ui;

pub const Counter = struct {
    pub const Props = void;

    pub fn render(ctx: *zui.Context, props: Props) zui.Element {
        _ = props;

        var count = ctx.useState(i32, 0);

        return ui.column(ctx, .{
            .style = .{ .gap = 12, .align_items = .center },
            .children = &.{
                ui.text(.{ .font_size = 32 },
                    std.fmt.allocPrint(ctx.arena, "{d}", .{count.get()}) catch "?"),
                ui.button(ctx, .{
                    .label = "+1",
                    .onclick = count.handler(struct {
                        fn inc(p: *i32) void { p.* += 1; }
                    }.inc),
                }),
            },
        });
    }
};

pub fn main() !void {
    try zui.launch(Counter, .{});
}
```

### A note on container widgets

Container widgets (`ui.column`, `ui.row`, `ui.rect`, `ui.spacer`,
`ui.button`) take the render `Context` as their first argument because they
copy their child list into the per-frame arena. This is required: a
`&.{ ... }` literal in Zig lives on the render function's stack and would
dangle once the function returns, while the element tree is only read later,
during reconciliation. Leaf widgets such as `ui.text` hold no children and
keep a plain `(style, content)` signature.

## Input coordinates and live resizing

Layout runs in logical (screen) pixels and the positions GLFW reports are in
the same space, so the two match by construction; the window module never
rescales cursor positions. `contentScale()` is only used to convert the
framebuffer (physical) size into the logical size the layout engine wants.

When the user drags a window edge, Win32 runs a modal sizing loop that
`glfwPollEvents` does not return from until the drag ends. zui therefore
installs the GLFW window-refresh callback and repaints from inside it, so
the window keeps showing content (re-created surface, re-laid-out tree)
while the drag is in progress instead of going black.

## The event queue and `clearRetainingCapacity`

Window callbacks push events (cursor movement, button presses, resize) into a
`EventQueue`; the frame loop `drain()`s them once per frame and dispatches each
to the hit-tested element. `drain()` returns the backing slice and resets the
queue with

```zig
self.events.items.len = 0;
```

deliberately *not* `clearRetainingCapacity()`. In Zig 0.16 the latter does
`@memset(self.items, undefined)`, which clobbers the very slice that was just
returned - every dispatched event then reads garbage (wrong tag, scrambled
fields). The symptom was total input failure: hover never fired and clicks
never reached their handler.

## Commands

```
zig build          build the demo + the render check
zig build run      run the interactive counter (Escape to quit)
zig build check    render check: resizes the window live and verifies the
                     redrawn framebuffer (exit 0 + RENDER_OK on success)
zig build test     unit tests for the layout engine and the reconciler
```

## How the MSVC dynamic runtime is wired up

The prebuilt Skia libraries and `zsk.cpp` are built against the dynamic MSVC
runtime (`/MD`), but Zig provides its own entry point, so the CRT startup
object inside `msvcrt.lib` (`crtexe.obj` -> `__scrt_common_main_seh`) never
runs. Two of its jobs still matter, and `zsk_init_crt()` (called from
`App.init`) replays them:

1. `__scrt_initialize_onexit_tables(0)` initializes the executable's onexit
   table. Without it the first `atexit()` call - Skia registers exit handlers
   from static constructors - jumps to the uninitialized sentinel and crashes.
   (`ucrtbase.dll`'s `_initialize_onexit_table` takes a *table pointer*
   argument and cannot be called standalone.)
2. `_initterm()` runs the `.CRT$XI*` / `.CRT$XC*` initializer tables (the
   boundary markers are declared in `zsk.cpp`), which execute the C and C++
   static initializers of the Skia static libraries.

Additionally, `msvcrt.lib`'s startup references internal `__acrt_*` /
`__vcrt_*` entry points that cl normally redirects to no-op stubs through
`/alternatename` linker directives; Zig cannot pass those, so equivalent
no-op stubs are defined in `zsk.cpp`. The `/MD` import libraries
(`msvcprt.lib`, `vcruntime.lib`, `ucrt.lib`) are linked before `msvcrt.lib`
so its static VCStartup objects (operator new/delete, `atexit`) resolve
first; `libvcruntime.lib` is deliberately not linked, exactly as the real
`/MD` model forbids.

## Status

A focused prototype: the whole pipeline (window -> events -> reactive
components -> flexbox -> Skia -> swap) works, but only a widget subset is
implemented and only the win32/GL backend exists.

## License

MIT (see `LICENSE`). zui embeds third-party software under their own
licenses: Skia (BSD, `vendor/skia-binaries/LICENSE_SKIA`) and GLFW (Zlib,
`vendor/glfw/LICENSE.md`).
