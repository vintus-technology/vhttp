const std = @import("std");
const http = std.http;

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip(); // skip the executable

    const method = try parse_method(&args);

    const url = args.next() orelse {
        std.debug.print("Specify a url\n", .{});
        std.process.exit(1);
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var client = http.Client{ .allocator = gpa.allocator() };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    const uri = try std.Uri.parse(url);

    var req = try client.open(method, uri, .{
        .server_header_buffer = &buf,
    });

    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    std.debug.print("{s} {s} -> {d} {s}\n", .{
        @tagName(method),
        url,
        @intFromEnum(req.response.status),
        @tagName(req.response.status),
    });

    var headers = req.response.iterateHeaders();

    while (headers.next()) |h| {
        std.debug.print("\x1b[35m{s}\x1b[0m {s}\n", .{ h.name, h.value });
    }

    _ = req.response.content_length orelse {
        // OK: No response body to show
        std.process.exit(0);
    };
    const body_size = 65536;
    var bbuffer: [body_size]u8 = undefined;
    const read_length = try req.readAll(&bbuffer);
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{s}", .{bbuffer[0..read_length]});
}

const ArgumentError = error{
    MissingHttpMethod,
    InvalidHttpMethod,
};

fn parse_method(args: *std.process.ArgIterator) ArgumentError!http.Method {
    const method = args.next() orelse return ArgumentError.MissingHttpMethod;

    inline for (std.meta.fields(http.Method)) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, method)) {
            return @enumFromInt(f.value);
        }
    }

    return ArgumentError.InvalidHttpMethod;
}
