//! OpenAI-compatible /chat/completions adapter: LM Studio by default,
//! and equally Ollama (`http://localhost:11434/v1`), llama.cpp's server
//! or anything else that speaks the same streaming shape.

const std = @import("std");
const domain = @import("domain.zig");
const provider = @import("provider.zig");
const i18n = @import("../i18n.zig");

const Message = domain.Message;
const StreamEvent = domain.StreamEvent;

pub const default_base_url = "http://localhost:1234/v1";

pub fn buildRequest(target: provider.Target, auth: provider.Auth, persona: []const u8, history: []const Message, bufs: *provider.Bufs) ?provider.Request {
    const url = provider.joinUrl(bufs, target.base_url, "/chat/completions") orelse return null;
    var headers: provider.HeaderList = .{ .bufs = bufs };
    headers.add("content-type", "application/json");
    headers.add("accept", "text/event-stream");
    if (auth.bearer.len > 0) headers.add("authorization", provider.bearerValue(bufs, auth.bearer) orelse return null);

    var w: std.Io.Writer = .fixed(&bufs.body);
    writeBody(&w, target.model, persona, history) catch return null;
    return .{ .url = url, .headers = headers.slice(), .body = w.buffered() };
}

fn writeBody(w: *std.Io.Writer, model: []const u8, persona: []const u8, history: []const Message) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    if (model.len > 0) {
        try s.objectField("model");
        try s.write(model);
    }
    try s.objectField("stream");
    try s.write(true);
    try s.objectField("messages");
    try s.beginArray();
    if (persona.len > 0) try writeMessage(&s, "system", persona);
    for (history) |m| try writeMessage(&s, m.role.wireName(), m.text);
    try s.endArray();
    try s.endObject();
}

fn writeMessage(s: *std.json.Stringify, role: []const u8, content: []const u8) !void {
    try s.beginObject();
    try s.objectField("role");
    try s.write(role);
    try s.objectField("content");
    try s.write(content);
    try s.endObject();
}

const Chunk = struct {
    choices: []const struct {
        delta: struct { content: ?[]const u8 = null } = .{},
    } = &.{},
    @"error": ?struct { message: []const u8 = "" } = null,
};

pub fn parseLine(line: []const u8, scratch: []u8) ?StreamEvent {
    const data = provider.sseData(line) orelse return null;
    if (std.mem.eql(u8, data, "[DONE]")) return .done;
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const chunk = std.json.parseFromSliceLeaky(Chunk, fba.allocator(), data, .{ .ignore_unknown_fields = true }) catch return null;
    if (chunk.@"error") |err| return .{ .failed = if (err.message.len > 0) err.message else i18n.t("The server reported an error", "サーバーがエラーを返しました") };
    if (chunk.choices.len == 0) return null;
    const content = chunk.choices[0].delta.content orelse return null;
    if (content.len == 0) return null;
    return .{ .delta = content };
}

const ModelList = struct {
    data: []const struct { id: []const u8 } = &.{},
};

/// First model id from a `GET /models` body, for Settings' Detect.
pub fn firstModelId(body: []const u8, scratch: []u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    const list = std.json.parseFromSliceLeaky(ModelList, fba.allocator(), body, .{ .ignore_unknown_fields = true }) catch return null;
    if (list.data.len == 0 or list.data[0].id.len == 0) return null;
    return list.data[0].id;
}

test "request body carries the persona as the system message" {
    const t = std.testing;
    var bufs: provider.Bufs = .{};
    const history = [_]Message{
        .{ .role = .user, .text = "こんにちは \"ボバ\"" },
        .{ .role = .assistant, .text = "やあ" },
        .{ .role = .user, .text = "line\nbreak" },
    };
    const req = buildRequest(.{ .base_url = "http://localhost:1234/v1/", .model = "qwen3-8b" }, .{}, "You are Boba.", &history, &bufs).?;
    try t.expectEqualStrings("http://localhost:1234/v1/chat/completions", req.url);
    try t.expectEqualStrings(
        "{\"model\":\"qwen3-8b\",\"stream\":true,\"messages\":[" ++
            "{\"role\":\"system\",\"content\":\"You are Boba.\"}," ++
            "{\"role\":\"user\",\"content\":\"こんにちは \\\"ボバ\\\"\"}," ++
            "{\"role\":\"assistant\",\"content\":\"やあ\"}," ++
            "{\"role\":\"user\",\"content\":\"line\\nbreak\"}]}",
        req.body,
    );
    try t.expectEqual(@as(usize, 2), req.headers.len);
}

test "an API key adds the Authorization header; an empty model is omitted" {
    const t = std.testing;
    var bufs: provider.Bufs = .{};
    const history = [_]Message{.{ .role = .user, .text = "hi" }};
    const req = buildRequest(.{ .base_url = "http://h/v1", .model = "" }, .{ .bearer = "sk-local" }, "", &history, &bufs).?;
    try t.expectEqual(@as(usize, 3), req.headers.len);
    try t.expectEqualStrings("authorization", req.headers[2].name);
    try t.expectEqualStrings("Bearer sk-local", req.headers[2].value);
    try t.expectEqualStrings("{\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}", req.body);
}

test "a request larger than the body buffer is refused rather than cut" {
    var bufs: provider.Bufs = .{};
    const big = "x" ** (provider.max_body_bytes);
    const history = [_]Message{.{ .role = .user, .text = big }};
    try std.testing.expect(buildRequest(.{ .base_url = "http://h/v1", .model = "m" }, .{}, "", &history, &bufs) == null);
}

test "stream lines map to deltas, done and failures" {
    const t = std.testing;
    var scratch: [4096]u8 = undefined;
    try t.expectEqualStrings("こんにちは", parseLine("data: {\"choices\":[{\"delta\":{\"content\":\"\\u3053\\u3093\\u306b\\u3061\\u306f\"}}]}", &scratch).?.delta);
    try t.expectEqualStrings("a\"b", parseLine("data: {\"id\":\"x\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"a\\\"b\"}}]}", &scratch).?.delta);
    try t.expect(parseLine("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}", &scratch) == null);
    try t.expect(parseLine("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}", &scratch) == null);
    try t.expect(parseLine("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}", &scratch) == null);
    try t.expect(parseLine("data: [DONE]", &scratch).? == .done);
    try t.expectEqualStrings("model not loaded", parseLine("data: {\"error\":{\"message\":\"model not loaded\"}}", &scratch).?.failed);
    try t.expect(parseLine("", &scratch) == null);
    try t.expect(parseLine("data: {not json", &scratch) == null);
}

test "firstModelId reads the /models listing" {
    var scratch: [4096]u8 = undefined;
    try std.testing.expectEqualStrings("qwen3-8b", firstModelId("{\"object\":\"list\",\"data\":[{\"id\":\"qwen3-8b\",\"object\":\"model\"},{\"id\":\"b\"}]}", &scratch).?);
    try std.testing.expect(firstModelId("{\"data\":[]}", &scratch) == null);
    try std.testing.expect(firstModelId("nope", &scratch) == null);
}
