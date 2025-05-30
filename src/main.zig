const std = @import("std");
const http = std.http;
const config = @import("config");
const ansi = @import("ansi.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    const exe = args.next() orelse unreachable;
    var request = try parse_args(allocator, &args);

    switch (request) {
        .root => {
            do_version();
            do_help(exe);
        },
        .version => do_version(),
        .help => do_help(exe),
        .http => |*r| try do_request(r, gpa.allocator()),
    }
}

fn show_status(req: *const http.Client.Request) void {
    std.debug.print("{d} {s}\n", .{
        @intFromEnum(req.response.status),
        @tagName(req.response.status),
    });
}

const style_request_header = ansi.build(.{
    .fg = .blue,
    .bold = true,
});

const style_response_header = ansi.build(.{
    .fg = .cyan,
    .bold = true,
});

fn show_headers(req: *const http.Client.Request) void {
    var headers = req.response.iterateHeaders();

    while (headers.next()) |h| {
        std.debug.print(style_response_header ++ "{s}" ++ ansi.reset ++ " {s}\n", .{ h.name, h.value });
    }
}

fn show_body(req: *http.Client.Request) !void {
    if (req.response.content_length == null and req.response.transfer_encoding == .none) {
        std.process.exit(0);
    }

    const stdout = std.io.getStdOut().writer();
    const chunk_size = 65536;
    var buffer: [chunk_size]u8 = undefined;
    var read_length: ?usize = null;
    while (read_length != 0) {
        read_length = try req.readAll(&buffer);
        try stdout.print("{s}", .{buffer[0..read_length.?]});
    }
}

fn do_version() void {
    std.debug.print("{s}\n", .{config.version});
}

fn do_help(exe: []const u8) void {
    std.debug.print(
        \\{s} <command/method> <url?> <options?>
        \\
        \\commands:
        \\  <method>    Sends an http request using the specified method
        \\              to the specified <url>
        \\              options:
        \\                <stdin>   Use stdin to pass a request body
        \\                -H        Set a header using "header: value" syntax
        \\  version     Shows version information
        \\  help        Shows this help menu
        \\
    , .{exe});
}

fn do_request(request: *RequestCommand, allocator: std.mem.Allocator) !void {
    defer request.deinit(allocator);

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf_headers: [4096]u8 = undefined;

    var req = try client.open(request.method, request.url, .{
        .server_header_buffer = &buf_headers,
        .extra_headers = request.headers,
    });
    defer req.deinit();

    const style_method = comptime ansi.build(.{
        .fg = .yellow,
    });

    std.debug.print("{s} " ++ style_method ++ "{s}" ++ ansi.reset ++ " {}\n", .{
        @tagName(req.version),
        @tagName(request.method),
        request.url,
    });
    for (req.extra_headers) |h| {
        std.debug.print(style_request_header ++ "{s}" ++ ansi.reset ++ " {s}\n", .{ h.name, h.value });
    }

    std.debug.print("sending...\n", .{});
    try req.send();

    // TODO: Request body does not get sent yet.
    const stdin = std.io.getStdIn();
    if (!stdin.isTty()) {
        const request_body = try stdin.readToEndAlloc(allocator, 10485760);
        defer allocator.free(request_body);
        req.transfer_encoding = .{ .content_length = request_body.len };
        var writer = req.writer();
        _ = try writer.write(request_body);
    } else {
        std.debug.print("No request body specified...\n", .{});
    }
    std.debug.print("finishing...\n", .{});
    try req.finish();
    std.debug.print("waiting...\n", .{});
    try req.wait();

    show_status(&req);
    show_headers(&req);
    try show_body(&req);
}

const ArgumentError = error{
    MissingCommand,
    InvalidHttpMethod,
};

const RequestCommand = struct {
    method: http.Method,
    url: std.Uri,
    headers: []const std.http.Header,

    pub fn deinit(self: *RequestCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
    }
};

const RootCommand = struct {};
const VersionCommand = struct {};
const HelpCommand = struct {};

const Command = union(enum) {
    root: RootCommand,
    version: VersionCommand,
    help: HelpCommand,
    http: RequestCommand,
};

fn parse_args(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !Command {
    return try parse_command(allocator, args);
}

fn parse_command(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !Command {
    const command = args.next() orelse return .{ .root = RootCommand{} };

    if (std.mem.eql(u8, command, "version")) {
        return .{
            .version = VersionCommand{},
        };
    }

    if (std.mem.eql(u8, command, "help")) {
        return .{
            .help = HelpCommand{},
        };
    }

    return try parse_request(allocator, command, args);
}

fn parse_request(
    allocator: std.mem.Allocator,
    command: [:0]const u8,
    args: *std.process.ArgIterator,
) !Command {
    const method = try parse_method(command);

    var url = args.next() orelse {
        std.debug.print("Specify a url\n", .{});
        std.process.exit(1);
    };

    var headers = std.ArrayList(std.http.Header).init(allocator);
    defer headers.deinit();

    while (true) {
        const arg = args.next() orelse break;
        const flag = arg[1..];

        switch (flag[0]) {
            'H' => {
                const a = args.next() orelse return error.MissingHeaderValue;
                var i = std.mem.indexOf(u8, a, ":") orelse {
                    return error.InvalidHttpHeader;
                };

                const name = a[0..i];
                while (true) {
                    i = i + 1;
                    if (!std.ascii.isWhitespace(a[i]) and a[i] != ':') {
                        break;
                    }
                }
                const value = a[i..a.len];

                try headers.append(.{
                    .name = name,
                    .value = value,
                });
            },
            else => return error.InvalidFlag,
        }
    }

    if (std.mem.indexOf(u8, url, "://") == null) {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try buf.appendSlice("https://");
        try buf.appendSlice(url);
        url = try buf.toOwnedSliceSentinel(0);
    }

    return .{
        .http = .{
            .url = try (std.Uri.parse(url)),
            .method = method,
            .headers = try headers.toOwnedSlice(),
        },
    };
}

fn parse_method(command: [:0]const u8) ArgumentError!http.Method {
    inline for (std.meta.fields(http.Method)) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, command)) {
            return @enumFromInt(f.value);
        }
    }

    return ArgumentError.InvalidHttpMethod;
}
