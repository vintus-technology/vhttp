const std = @import("std");
const http = std.http;
const config = @import("config");

fn show_status(req: *const http.Client.Request) void {
    std.debug.print("{d} {s}\n", .{
        @intFromEnum(req.response.status),
        @tagName(req.response.status),
    });
}

fn show_headers(req: *const http.Client.Request) void {
    var headers = req.response.iterateHeaders();

    while (headers.next()) |h| {
        std.debug.print("\x1b[35m{s}\x1b[0m {s}\n", .{ h.name, h.value });
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

fn do_request(request: *const RequestCommand, allocator: std.mem.Allocator) !void {
    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;

    var req = try client.open(request.method, request.url, .{
        .server_header_buffer = &buf,
    });

    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    show_status(&req);
    show_headers(&req);
    try show_body(&req);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const request = try parse_args();

    switch (request) {
        .version => do_version(),
        .http => |*r| try do_request(r, gpa.allocator()),
    }
}

const ArgumentError = error{
    MissingCommand,
    InvalidHttpMethod,
};

const RequestCommand = struct {
    method: http.Method,
    url: std.Uri,
};

const VersionCommand = struct {};

const Command = union(enum) {
    version: VersionCommand,
    http: RequestCommand,
};

fn parse_args() !Command {
    var args = std.process.args();
    _ = args.skip(); // skip the executable

    return try parse_command(&args);
}

fn parse_command(args: *std.process.ArgIterator) !Command {
    const command = args.next() orelse return ArgumentError.MissingCommand;

    if (std.mem.eql(u8, command, "version")) {
        return Command{
            .version = VersionCommand{},
        };
    }

    return try parse_request(command, args);
}

fn parse_request(command: [:0]const u8, args: *std.process.ArgIterator) !Command {
    const method = try parse_method(command);

    const url = args.next() orelse {
        std.debug.print("Specify a url\n", .{});
        std.process.exit(1);
    };

    return Command{
        .http = .{
            .url = try std.Uri.parse(url),
            .method = method,
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
