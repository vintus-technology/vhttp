const base16 = enum {
    default,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
};

pub fn build(comptime props: properties) []const u8 {
    comptime {
        if (props.bg == null and props.fg == null and props.bold == false) {
            return "";
        }

        var dirty = false;
        var style: []const u8 = "\x1b[";
        if (props.fg) |fg| {
            style = style ++ switch (fg) {
                .default => "39",
                .black => "30",
                .red => "31",
                .green => "32",
                .yellow => "33",
                .blue => "34",
                .magenta => "35",
                .cyan => "36",
                .white => "37",
            };
            dirty = true;
        }

        if (props.bg) |bg| {
            if (dirty) {
                style = style ++ ";";
            }
            style = style ++ switch (bg) {
                .default => "49",
                .black => "40",
                .red => "41",
                .green => "42",
                .yellow => "43",
                .blue => "44",
                .magenta => "45",
                .cyan => "46",
                .white => "47",
            };
        }

        if (props.bold) {
            if (dirty) {
                style = style ++ ";";
            }
            style = style ++ "1";
        }

        style = style ++ "m";

        return style;
    }
}

const properties = struct {
    bold: bool = false,
    bg: ?base16 = null,
    fg: ?base16 = null,
};

pub const reset = "\x1b[0m";
