//! The WeChat 4.0 for Windows palette plus the shared text styles.
//!
//! The colors were sampled pixel by pixel from a reference screenshot of
//! the real client: the navigation rail and the title bar are the mica
//! material (translucent over the desktop) which a solid color can only
//! approximate - `rail` is the sampled average of that blend. Everything
//! else is the exact sampled value: the session pane #EEEef0, the chat
//! surface #FAFAFA, the sent bubble #9DF29F, the received bubble #EEEef0.

const zui = @import("zui");
const element = zui.element;

pub const c = struct {
    /// Mica (translucent) over the desktop: the sampled average of the rail
    /// and the title bar strip. Solid, because zui windows are opaque.
    pub const rail = 0xFFCFCFCF;
    pub const rail_icon = 0xFF9A9A9A;
    pub const rail_icon_active = 0xFF00C375;
    pub const rail_hover = 0xFFE2E2E2;
    pub const rail_avatar = 0xFF86A2C8;

    pub const panel = 0xFFEEEFF1;
    pub const panel_search = 0xFFFAFAFA;
    pub const panel_search_border = 0xFFF9F9F9;
    pub const item_hover = 0xFFE9E9EA;
    pub const item_selected = 0xFFE3E3E4;
    pub const item_separator = 0xFFE6E6E7;

    pub const chat_bg = 0xFFFAFAFA;
    pub const header = 0xFFFAFAFA;
    pub const header_border = 0xFFF0F0F0;
    pub const input_bg = 0xFFFAFAFA;
    /// The border of the composer card (2px top/bottom, 1px sides, r6),
    /// measured off the reference screenshot (#EAEAEA).
    pub const composer_border = 0xFFEAEAEA;
    /// The toolbar icons: 18x18 line icons stroked in #4C4C4C.
    pub const toolbar_icon = 0xFF4C4C4C;
    /// The caret: WeChat blinks brand green, even over dark text.
    pub const caret = 0xFF00C375;
    /// The emoji picker panel: white over the chat surface, 1px outline.
    pub const emoji_panel = 0xFFFFFFFF;
    pub const emoji_panel_border = 0xFFE5E6E8;
    pub const emoji_hover = 0xFFF2F3F5;

    /// The height shared by the chat header and the session pane's search
    /// strip: both top bands occupy the same vertical space (48px) so the
    /// message list and the session list start at the same y, as in the
    /// reference. The chat header is 47px plus its 1px divider.
    pub const top_strip = 48;

    /// The composer card (the reference's input box, y 578..710): a
    /// floating rounded panel inset from the chat column's edges (6px
    /// left, 8px right), 132 tall: 2px border, a 94px editor, a 28px
    /// tool row and a 6px bottom inset - and it stops 3px short of the
    /// window's bottom edge, leaving a breathing strip under it.
    pub const composer_h = 132;
    pub const toolbar_h = 28;
    pub const composer_radius = 6;
    pub const composer_inset_left = 6;
    pub const composer_inset_right = 8;
    pub const composer_bottom_gap = 3;
    /// The emoji picker panel opens left-aligned with the smiley in the
    /// tool row: column edge + inset + border + the row's left padding.
    pub const composer_pad = 20;

    pub const bubble_me = 0xFF9DF29F;
    pub const bubble_other = 0xFFEEEFF1;
    pub const bubble_text = 0xFF161616;

    pub const text_primary = 0xFF19191A;
    pub const text_secondary = 0xFFB2B2B2;
    pub const text_preview = 0xFF9A9A9A;

    pub const badge = 0xFFF76162;
    pub const send = 0xFF07C160;
    pub const send_disabled = 0xFFEDEDED;
    pub const send_disabled_text = 0xFFA5A5A5;

    pub const pill = 0xFFEEEEF0;
    pub const pill_text = 0xFF8A8A8A;
    pub const icon_dark = 0xFF5A5A5A;

    pub const font = "Microsoft YaHei";
};

/// A text style in the app font.
pub fn txt(size: f32, color: u32) element.Style {
    return .{ .font_family = c.font, .font_size = size, .color = color };
}

pub fn bubbleTextStyle() element.Style {
    var s = txt(14, c.bubble_text);
    s.line_height = 1.45;
    return s;
}

pub fn nameStyle() element.Style {
    var s = txt(15, c.text_primary);
    s.max_lines = 1;
    s.flex_grow = 1;
    return s;
}

pub fn previewStyle() element.Style {
    var s = txt(12.5, c.text_preview);
    s.max_lines = 1;
    s.flex_grow = 1;
    return s;
}

pub fn headerNameStyle() element.Style {
    var s = txt(16, c.text_primary);
    s.font_weight = .semibold;
    return s;
}
