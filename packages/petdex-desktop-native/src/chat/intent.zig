//! Commands the pet can carry out. A message matches only when the whole
//! trimmed line is one command, so a mention of a timer mid-sentence is
//! still just conversation.

const std = @import("std");

pub const max_fact_chars = 80;

pub const Verb = enum { start, pause, @"resume", reset };

pub const Timer = struct {
    verb: Verb,
    /// Countdown length, when the line named one. Pomodoro never carries it.
    seconds: ?u16 = null,
    pomodoro: bool = false,
};

pub const Intent = union(enum) {
    timer: Timer,
    open,
    /// A slice of the input, trimmed and cut to `max_fact_chars` code points.
    remember: []const u8,
    forget,
};

pub fn parse(text: []const u8) ?Intent {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0) return null;
    if (exact(line, &.{ "開いて", "待ってるの開いて", "待ってるやつ開いて", "open" })) return .open;
    if (exact(line, &.{ "忘れて", "forget" })) return .forget;
    if (remember(line)) |fact| return .{ .remember = fact };
    if (timer(line)) |cmd| return .{ .timer = cmd };
    return null;
}

fn exact(line: []const u8, phrases: []const []const u8) bool {
    const body = stripEnd(line);
    for (phrases) |phrase| if (same(body, phrase)) return true;
    return false;
}

fn stripEnd(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        if (s[end - 1] == '.' or s[end - 1] == '!' or s[end - 1] == '?') {
            end -= 1;
            continue;
        }
        if (end >= 3 and (std.mem.endsWith(u8, s[0..end], "。") or std.mem.endsWith(u8, s[0..end], "！") or std.mem.endsWith(u8, s[0..end], "？"))) {
            end -= 3;
            continue;
        }
        break;
    }
    return std.mem.trim(u8, s[0..end], " \t");
}

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return same(s[0..prefix.len], prefix);
}

fn remember(line: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "覚えておいて", "覚えて", "remember" };
    for (prefixes) |prefix| {
        if (!startsWith(line, prefix)) continue;
        var rest = line[prefix.len..];
        if (rest.len > 0 and std.ascii.isAlphabetic(rest[0])) continue;
        rest = skipSep(rest);
        rest = std.mem.trim(u8, rest, " \t\r\n");
        if (rest.len == 0) return null;
        return takeChars(rest, max_fact_chars);
    }
    return null;
}

fn timer(line: []const u8) ?Timer {
    const body = stripEnd(line);
    var seconds: ?u16 = null;
    var rest = body;
    if (body.len > 0 and body[0] >= '0' and body[0] <= '9') {
        const dur = leadingDuration(body) orelse return null;
        if (dur.seconds == 0 or dur.seconds > 5999) return null;
        seconds = @intCast(dur.seconds);
        rest = std.mem.trim(u8, dur.rest, " \t");
    }
    const noun = eatNoun(rest) orelse return null;
    if (seconds != null and noun.pomodoro) return null;
    const verb = verbOf(skipSep(noun.rest)) orelse return null;
    return .{ .verb = verb, .seconds = seconds, .pomodoro = noun.pomodoro };
}

const Duration = struct { seconds: u32, rest: []const u8 };

fn leadingDuration(s: []const u8) ?Duration {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == 0) return null;
    const n = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
    var j = i;
    while (j < s.len and s[j] == ' ') j += 1;
    const units = [_]struct { []const u8, u32 }{
        .{ "minutes", 60 },
        .{ "minute", 60 },
        .{ "mins", 60 },
        .{ "min", 60 },
        .{ "seconds", 1 },
        .{ "second", 1 },
        .{ "secs", 1 },
        .{ "sec", 1 },
        .{ "分", 60 },
        .{ "秒", 1 },
    };
    for (units) |unit| {
        if (!startsWith(s[j..], unit[0])) continue;
        const seconds = std.math.mul(u32, n, unit[1]) catch return null;
        return .{ .seconds = seconds, .rest = s[j + unit[0].len ..] };
    }
    return null;
}

const Noun = struct { pomodoro: bool, rest: []const u8 };

fn eatNoun(s: []const u8) ?Noun {
    const nouns = [_]struct { []const u8, bool }{
        .{ "pomodoro", true },
        .{ "ポモドーロ", true },
        .{ "timer", false },
        .{ "タイマー", false },
    };
    for (nouns) |noun| {
        if (!startsWith(s, noun[0])) continue;
        return .{ .pomodoro = noun[1], .rest = s[noun[0].len..] };
    }
    return null;
}

fn verbOf(s: []const u8) ?Verb {
    const body = std.mem.trim(u8, s, " \t");
    const verbs = [_]struct { []const u8, Verb }{
        .{ "一時停止", .pause },
        .{ "はじめて", .start },
        .{ "始めて", .start },
        .{ "スタート", .start },
        .{ "リセット", .reset },
        .{ "開始", .start },
        .{ "止めて", .pause },
        .{ "再開", .@"resume" },
        .{ "resume", .@"resume" },
        .{ "pause", .pause },
        .{ "start", .start },
        .{ "reset", .reset },
    };
    for (verbs) |verb| if (same(body, verb[0])) return verb[1];
    return null;
}

fn skipSep(s: []const u8) []const u8 {
    var rest = s;
    while (rest.len > 0) {
        if (rest[0] == ' ' or rest[0] == '\t' or rest[0] == ',' or rest[0] == ':' or rest[0] == ';') {
            rest = rest[1..];
            continue;
        }
        if (std.mem.startsWith(u8, rest, "、") or std.mem.startsWith(u8, rest, "：") or std.mem.startsWith(u8, rest, "　")) {
            rest = rest[3..];
            continue;
        }
        break;
    }
    return rest;
}

fn takeChars(s: []const u8, max: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < max) {
        const width = std.unicode.utf8ByteSequenceLength(s[i]) catch return s[0..i];
        if (i + width > s.len) return s[0..i];
        i += width;
        n += 1;
    }
    return s[0..i];
}

test "only a whole line is a command" {
    const t = std.testing;
    try t.expect(parse("タイマーのことなんだけど") == null);
    try t.expect(parse("今タイマー止めてほしい") == null);
    try t.expect(parse("please open the pane") == null);
    try t.expect(parse("覚えて") == null);
    try t.expect(parse("忘れてあれ") == null);
    try t.expect(parse("remembering the day") == null);
    try t.expect(parse("") == null);

    try t.expectEqual(Verb.start, parse("25分タイマー始めて").?.timer.verb);
    try t.expectEqual(@as(?u16, 1500), parse("25分タイマー始めて").?.timer.seconds);
    try t.expectEqual(@as(?u16, 300), parse("5 min timer start").?.timer.seconds);
    try t.expectEqual(@as(?u16, 90), parse("90秒タイマー開始").?.timer.seconds);
    try t.expectEqual(Verb.pause, parse("タイマー一時停止").?.timer.verb);
    try t.expectEqual(Verb.pause, parse("TIMER pause").?.timer.verb);
    try t.expectEqual(Verb.@"resume", parse("timer resume").?.timer.verb);
    try t.expectEqual(Verb.reset, parse("タイマー、リセット").?.timer.verb);
    try t.expect(parse("ポモドーロ始めて").?.timer.pomodoro);
    try t.expect(parse("25分ポモドーロ始めて") == null);
    try t.expect(parse("100分タイマー開始") == null);
    try t.expect(parse("0秒タイマー開始") == null);

    try t.expectEqual(Intent.open, parse("開いて").?);
    try t.expectEqual(Intent.open, parse("待ってるやつ開いて").?);
    try t.expectEqual(Intent.open, parse("Open.").?);
    try t.expectEqual(Intent.forget, parse("忘れて").?);
    try t.expectEqual(Intent.forget, parse("FORGET").?);

    try t.expectEqualStrings("呼び方は先生", parse("覚えて、呼び方は先生").?.remember);
    try t.expectEqualStrings("call me sensei", parse("Remember: call me sensei").?.remember);
    const long = "あ" ** 90;
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "覚えておいて {s}", .{long}) catch unreachable;
    try t.expectEqual(@as(usize, max_fact_chars * 3), parse(line).?.remember.len);
    try t.expect(std.unicode.utf8ValidateSlice(parse(line).?.remember));
}
