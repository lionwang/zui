//! Design tokens for the default component library.
//!
//! Components read `theme.active` when they pick their own colors, so
//! flipping it before the next frame re-skins every default-styled
//! component. Colors a caller passes through an argument's `style` always
//! win over the palette.
//!
//! ```zig
//! zui.ui.theme.active = zui.ui.theme.dark;
//! ```

const std = @import("std");

/// A full palette of ARGB colors (Skia's native format, 0xAARRGGBB).
pub const Palette = struct {
    background: u32 = 0xFFFFFFFF,
    foreground: u32 = 0xFF18181B,
    /// Panels, inputs, popovers: anything elevated above the background.
    surface: u32 = 0xFFFFFFFF,
    surface_hover: u32 = 0xFFF4F4F5,
    border: u32 = 0xFFE4E4E7,
    muted: u32 = 0xFFF4F4F5,
    muted_foreground: u32 = 0xFF71717A,
    primary: u32 = 0xFF2563EB,
    primary_foreground: u32 = 0xFFFFFFFF,
    primary_hover: u32 = 0xFF1D4ED8,
    danger: u32 = 0xFFDC2626,
    danger_foreground: u32 = 0xFFFFFFFF,
    success: u32 = 0xFF16A34A,
    warning: u32 = 0xFFEA8C00,
    /// The dim layer behind a modal dialog.
    scrim: u32 = 0x66000000,
    /// A translucent focus / active ring.
    focus_ring: u32 = 0x662563EB,
};

/// The default light palette (shadcn-style neutrals + a blue accent).
pub const light = Palette{};

pub const dark = Palette{
    .background = 0xFF09090B,
    .foreground = 0xFFFAFAFA,
    .surface = 0xFF18181B,
    .surface_hover = 0xFF27272A,
    .border = 0xFF3F3F46,
    .muted = 0xFF27272A,
    .muted_foreground = 0xFFA1A1AA,
    .primary = 0xFF3B82F6,
    .primary_hover = 0xFF60A5FA,
    .danger = 0xFFEF4444,
    .scrim = 0x99000000,
    .focus_ring = 0x663B82F6,
};

/// The palette every default-styled component renders with. Assign at
/// runtime to switch themes; the change shows up on the next frame.
pub var active = light;

/// Linear interpolation of two ARGB colors (each channel, alpha included).
/// Written with an explicit branch clamp: `@intFromFloat(@min/@max)` of a
/// saturated value hit a compiler crash when the function was inlined with
/// comptime color arguments.
pub fn mix(a: u32, b: u32, t: f32) u32 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    const m = af + (bf - af) * t;
    if (m <= 0) return 0;
    if (m >= 4294967295.0) return 0xFFFFFFFF;
    return @intFromFloat(m);
}

/// Replace the alpha channel of `c` (0..255).
pub fn withAlpha(c: u32, alpha: u8) u32 {
    return (c & 0x00FFFFFF) | (@as(u32, alpha) << 24);
}

/// White on dark backgrounds, near-black on light ones - a readable default
/// for text on a color the caller picked.
pub fn contrast(bg: u32) u32 {
    const r: f32 = @floatFromInt((bg >> 16) & 0xFF);
    const g: f32 = @floatFromInt((bg >> 8) & 0xFF);
    const b: f32 = @floatFromInt(bg & 0xFF);
    return if ((0.299 * r + 0.587 * g + 0.114 * b) / 255.0 < 0.5) 0xFFFFFFFF else 0xFF0A0A0A;
}
