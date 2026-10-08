//! Vector-path icon data (a 24x24 view box, no image assets).

const zui = @import("zui");
const element = zui.element;

const P = element.Point;

pub const icons = struct {
    pub const chat = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 3.5, .top = 4, .right = 20.5, .bottom = 15 }, .radius = 4 } },
        .{ .move_to = .{ .x = 7, .y = 14.6 } },
        .{ .line_to = .{ .x = 5.5, .y = 19.6 } },
        .{ .line_to = .{ .x = 10.6, .y = 14.6 } },
        .{ .close = {} },
    };

    pub const person = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 8.5, .top = 3, .right = 15.5, .bottom = 10 }, .radius = 3.5 } },
        .{ .move_to = .{ .x = 5, .y = 20.5 } },
        .{ .quad_to = .{ .c = .{ .x = 5, .y = 12.5 }, .p = .{ .x = 12, .y = 12.5 } } },
        .{ .quad_to = .{ .c = .{ .x = 19, .y = 12.5 }, .p = .{ .x = 19, .y = 20.5 } } },
        .{ .close = {} },
    };

    pub const star = [_]element.PathOp{
        .{ .move_to = .{ .x = 12, .y = 2.6 } },
        .{ .line_to = .{ .x = 14.4, .y = 8.7 } },
        .{ .line_to = .{ .x = 21, .y = 9.1 } },
        .{ .line_to = .{ .x = 15.9, .y = 13.2 } },
        .{ .line_to = .{ .x = 17.6, .y = 19.7 } },
        .{ .line_to = .{ .x = 12, .y = 16.1 } },
        .{ .line_to = .{ .x = 6.4, .y = 19.7 } },
        .{ .line_to = .{ .x = 8.1, .y = 13.2 } },
        .{ .line_to = .{ .x = 3, .y = 9.1 } },
        .{ .line_to = .{ .x = 9.6, .y = 8.7 } },
        .{ .close = {} },
    };

    pub const folder = [_]element.PathOp{
        .{ .move_to = .{ .x = 3, .y = 7 } },
        .{ .line_to = .{ .x = 9.5, .y = 7 } },
        .{ .line_to = .{ .x = 11.5, .y = 9 } },
        .{ .line_to = .{ .x = 21, .y = 9 } },
        .{ .line_to = .{ .x = 21, .y = 19 } },
        .{ .line_to = .{ .x = 3, .y = 19 } },
        .{ .close = {} },
    };

    // Camcorder: body with a lens protruding to the right.
    pub const video = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 2.5, .top = 7, .right = 16.5, .bottom = 17.5 }, .radius = 3 } },
        .{ .move_to = .{ .x = 16.8, .y = 10 } },
        .{ .line_to = .{ .x = 21, .y = 7.5 } },
        .{ .line_to = .{ .x = 21, .y = 16.5 } },
        .{ .line_to = .{ .x = 16.8, .y = 14 } },
        .{ .close = {} },
    };

    // Camera with a flash dot (the 朋友圈 icon).
    pub const camera = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 2.5, .top = 6, .right = 16, .bottom = 17.5 }, .radius = 3 } },
        .{ .rrect = .{ .box = .{ .left = 12.8, .top = 2.5, .right = 17.6, .bottom = 7.3 }, .radius = 2.4 } },
        .{ .move_to = .{ .x = 9.6, .y = 9.6 } },
        .{ .quad_to = .{ .c = .{ .x = 9.6, .y = 7.6 }, .p = .{ .x = 11.6, .y = 7.6 } } },
        .{ .quad_to = .{ .c = .{ .x = 13.6, .y = 7.6 }, .p = .{ .x = 13.6, .y = 9.6 } } },
        .{ .line_to = .{ .x = 13.6, .y = 11 } },
        .{ .line_to = .{ .x = 9.6, .y = 11 } },
        .{ .close = {} },
    };

    pub const grid = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 3, .top = 3, .right = 10.4, .bottom = 10.4 }, .radius = 1.6 } },
        .{ .rrect = .{ .box = .{ .left = 13.6, .top = 3, .right = 21, .bottom = 10.4 }, .radius = 1.6 } },
        .{ .rrect = .{ .box = .{ .left = 3, .top = 13.6, .right = 10.4, .bottom = 21 }, .radius = 1.6 } },
        .{ .rrect = .{ .box = .{ .left = 13.6, .top = 13.6, .right = 21, .bottom = 21 }, .radius = 1.6 } },
    };

    // Sliders (the settings icon).
    pub const settings = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 3, .top = 5.4, .right = 21, .bottom = 7.2 }, .radius = 0.9 } },
        .{ .rrect = .{ .box = .{ .left = 3.8, .top = 3.8, .right = 8.8, .bottom = 8.8 }, .radius = 2.5 } },
        .{ .rrect = .{ .box = .{ .left = 3, .top = 11.4, .right = 21, .bottom = 13.2 }, .radius = 0.9 } },
        .{ .rrect = .{ .box = .{ .left = 14.8, .top = 9.8, .right = 19.8, .bottom = 14.8 }, .radius = 2.5 } },
        .{ .rrect = .{ .box = .{ .left = 3, .top = 17.4, .right = 21, .bottom = 19.2 }, .radius = 0.9 } },
        .{ .rrect = .{ .box = .{ .left = 7.8, .top = 15.8, .right = 12.8, .bottom = 20.8 }, .radius = 2.5 } },
    };

    pub const dots_v = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 10.5, .top = 5.5, .right = 13.5, .bottom = 8.5 }, .radius = 1.5 } },
        .{ .rrect = .{ .box = .{ .left = 10.5, .top = 10.5, .right = 13.5, .bottom = 13.5 }, .radius = 1.5 } },
        .{ .rrect = .{ .box = .{ .left = 10.5, .top = 15.5, .right = 13.5, .bottom = 18.5 }, .radius = 1.5 } },
    };

    pub const dots_h = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 4.5, .top = 10.5, .right = 7.5, .bottom = 13.5 }, .radius = 1.5 } },
        .{ .rrect = .{ .box = .{ .left = 10.5, .top = 10.5, .right = 13.5, .bottom = 13.5 }, .radius = 1.5 } },
        .{ .rrect = .{ .box = .{ .left = 16.5, .top = 10.5, .right = 19.5, .bottom = 13.5 }, .radius = 1.5 } },
    };

    pub const document = [_]element.PathOp{
        .{ .move_to = .{ .x = 6.5, .y = 3 } },
        .{ .line_to = .{ .x = 13.5, .y = 3 } },
        .{ .line_to = .{ .x = 19.5, .y = 9 } },
        .{ .line_to = .{ .x = 19.5, .y = 21 } },
        .{ .line_to = .{ .x = 6.5, .y = 21 } },
        .{ .close = {} },
    };

    // Magnifier (stroked).
    pub const search = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 3.5, .top = 3.5, .right = 14, .bottom = 14 }, .radius = 5.25 } },
        .{ .move_to = .{ .x = 16, .y = 16 } },
        .{ .line_to = .{ .x = 20.5, .y = 20.5 } },
    };

    // Crop / screenshot frame (stroked).
    pub const crop = [_]element.PathOp{
        .{ .move_to = .{ .x = 3, .y = 9.5 } },
        .{ .line_to = .{ .x = 3, .y = 3.5 } },
        .{ .line_to = .{ .x = 9.5, .y = 3.5 } },
        .{ .move_to = .{ .x = 14.5, .y = 3.5 } },
        .{ .line_to = .{ .x = 21, .y = 3.5 } },
        .{ .line_to = .{ .x = 21, .y = 9.5 } },
        .{ .move_to = .{ .x = 21, .y = 14.5 } },
        .{ .line_to = .{ .x = 21, .y = 20.5 } },
        .{ .line_to = .{ .x = 14.5, .y = 20.5 } },
        .{ .move_to = .{ .x = 9.5, .y = 20.5 } },
        .{ .line_to = .{ .x = 3, .y = 20.5 } },
        .{ .line_to = .{ .x = 3, .y = 14.5 } },
    };

    // The composer toolbar glyphs, every one traced off the reference
    // screenshot's tool row (same box sizes and stroke counts): the smiley
    // (18x18, opens the emoji picker), the file transfer (a landscape
    // document with a folded corner, ink 18x14), and the scheduled-send
    // clock (18x18, hands up and up-right). The reply icon (13x18) is too
    // tall for a square viewBox, so it is drawn as a bordered rounded rect
    // with a tail in `chat_room` instead.
    pub const smile_line = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 2, .top = 2, .right = 22, .bottom = 22 }, .radius = 10 } },
        // eyes at y 5..7, x 5..7 / 11..13 (reference px, x1.33 the viewBox)
        .{ .rrect = .{ .box = .{ .left = 6.7, .top = 6.7, .right = 9.3, .bottom = 9.3 }, .radius = 1.3 } },
        .{ .rrect = .{ .box = .{ .left = 14.7, .top = 6.7, .right = 17.3, .bottom = 9.3 }, .radius = 1.3 } },
        // the open mouth: an oval outline, x 6..13 y 9..13 in reference px
        .{ .rrect = .{ .box = .{ .left = 8.4, .top = 12.4, .right = 15.6, .bottom = 17 }, .radius = 2.6 } },
    };
    // A landscape document with a folded corner and one content line.
    pub const file_line = [_]element.PathOp{
        .{ .move_to = .{ .x = 1.5, .y = 4.5 } },
        .{ .line_to = .{ .x = 13, .y = 4.5 } },
        .{ .line_to = .{ .x = 22.5, .y = 12.5 } },
        .{ .line_to = .{ .x = 22.5, .y = 20.5 } },
        .{ .line_to = .{ .x = 1.5, .y = 20.5 } },
        .{ .close = {} },
        .{ .move_to = .{ .x = 5.5, .y = 10.5 } },
        .{ .line_to = .{ .x = 18.5, .y = 10.5 } },
    };
    // Scheduled send: a clock with the hands up and up-right.
    pub const clock_line = [_]element.PathOp{
        .{ .rrect = .{ .box = .{ .left = 2, .top = 2, .right = 22, .bottom = 22 }, .radius = 10 } },
        .{ .move_to = .{ .x = 12, .y = 12 } },
        .{ .line_to = .{ .x = 12, .y = 7.6 } },
        .{ .move_to = .{ .x = 12, .y = 12 } },
        .{ .line_to = .{ .x = 15.6, .y = 9.6 } },
    };
};
