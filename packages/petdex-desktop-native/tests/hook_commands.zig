//! Emit the production hook commands for the open-stdin integration test.
const std = @import("std");
const builtin = @import("builtin");
const hooks = @import("hooks");

pub fn main(init: std.process.Init) !void {
    for ([_][]const u8{ "codex", "cursor", "copilot", "windsurf" }) |agent| {
        if (builtin.os.tag != .windows and (std.mem.eql(u8, agent, "copilot") or std.mem.eql(u8, agent, "windsurf"))) continue;
        var buf: [512]u8 = undefined;
        const command = hooks.canonicalCommand(&buf, "post", agent) orelse return error.CommandTooLong;
        const json = try std.json.Stringify.valueAlloc(init.gpa, .{ .agent = agent, .command = command }, .{});
        defer init.gpa.free(json);
        try std.Io.File.stdout().writeStreamingAll(init.io, json);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
