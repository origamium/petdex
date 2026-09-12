//! The hook bubbles' motion. Each conversation is a soft circle floating
//! over the pet: it rises out of the pet's head, drifts a little around its
//! place in the cluster, nudges its neighbours aside, swells into a card
//! when opened, and pops a moment after its agent is done.
//!
//! Pure on purpose (no SDK, no clock): the caller feeds the conversation
//! list and a time step and draws what `shape` reports, so a test steps the
//! same motion the window shows.

const std = @import("std");

/// One body per conversation; main asserts it matches the mailbox.
pub const capacity = 10;
pub const diameter: f32 = 40;
pub const radius: f32 = diameter / 2;
/// Room around the cluster for the drift and the pop's swell.
pub const margin: f32 = 8;
/// Home places per row, and the space between them.
pub const per_row = 6;
pub const gap: f32 = 10;
/// Two bubbles, or a bubble and the card, never quite touch.
const spacing: f32 = 4;

const drift_px: f32 = 3;
const spring: f32 = 24;
const damping: f32 = 7;
const rise_speed: f32 = 160;
const grow_s: f32 = 0.35;
const open_s: f32 = 0.22;
const pop_s: f32 = 0.25;
/// Below this speed (points per second) a resting bubble counts as still.
const settle_speed: f32 = 0.5;
/// A stall or a sleeping machine must not teleport anything.
const max_dt: f32 = 0.05;

pub const Status = enum { working, waiting, failed, done };

/// What the caller knows about one conversation this tick.
pub const Entry = struct {
    /// Never 0; 0 marks a free body.
    id: u64,
    status: Status,
    /// The agent's cell in the icon strip, kept on the body so a popping
    /// bubble still draws after its conversation is gone.
    icon: u8 = 0,
};

pub const Body = struct {
    id: u64 = 0,
    status: Status = .working,
    icon: u8 = 0,
    /// Arrival order; decides the body's place in the cluster.
    seq: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    /// Each 0..1: growing in, swelling into the card, popping.
    born: f32 = 0,
    open: f32 = 0,
    pop: f32 = 0,
    /// Its conversation left the list: it pops now.
    leaving: bool = false,

    pub fn live(self: Body) bool {
        return self.id != 0;
    }

    /// Working and waiting bubbles sway; finished and failed ones rest,
    /// their badge saying enough.
    fn sways(self: Body) bool {
        return self.status == .working or self.status == .waiting;
    }

    /// Holds a place in the cluster (not on its way out).
    fn staying(self: Body) bool {
        return self.id != 0 and !self.leaving and self.pop == 0;
    }
};

pub const Layout = struct {
    width: f32,
    height: f32,
    /// Below the pet: the cluster fills from the top edge.
    flipped: bool = false,
    card_w: f32,
    card_h: f32,
    card_radius: f32,
};

/// A body as drawn: a rounded rect centered on (x, y), a circle until it
/// opens into the card.
pub const Shape = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    scale: f32,
    alpha: f32,
    /// Eased 0..1 progress into the card.
    open: f32,
};

const Point = struct { x: f32, y: f32 };

/// The narrowest window that fits a full row, and a card with a bubble's
/// lane on each side of it.
pub fn contentWidth(card_w: f32) f32 {
    const row: f32 = per_row * diameter + (per_row - 1) * gap;
    return @max(row, card_w + 2 * (diameter + spacing)) + 2 * margin;
}

/// The window height for `count` bubbles, one of them open as a card when
/// `open`: the card takes the row by the pet, two bubbles sit beside it,
/// and the rest fill rows beyond it.
pub fn contentHeight(count: usize, open: bool, card_h: f32) f32 {
    if (!open) return 2 * margin + rowsHeight(@max(count, 1));
    const beyond = (count -| 1) -| 2;
    const rows = rowsHeight(beyond);
    return 2 * margin + card_h + (if (rows > 0) gap + rows else 0);
}

fn rowsHeight(count: usize) f32 {
    if (count == 0) return 0;
    const rows: f32 = @floatFromInt((count + per_row - 1) / per_row);
    return rows * diameter + (rows - 1) * gap;
}

pub fn shape(b: Body, layout: Layout) Shape {
    const opened = smooth(b.open);
    return .{
        .x = b.x,
        .y = b.y,
        .w = lerp(diameter, layout.card_w, opened),
        .h = lerp(diameter, layout.card_h, opened),
        .radius = lerp(radius, layout.card_radius, opened),
        .scale = (0.4 + 0.6 * easeOut(b.born)) * (1 + 0.25 * b.pop),
        .alpha = @min(1, b.born * 3) * (1 - b.pop),
        .open = opened,
    };
}

pub const Sim = struct {
    bodies: [capacity]Body = @splat(.{}),
    /// The conversation shown as a card, 0 for none.
    open_id: u64 = 0,
    seq: u32 = 0,
    t: f32 = 0,
    /// The layout height of the last step.
    height: f32 = 0,

    /// Match the conversation list to the bodies by id. New conversations
    /// rise out of the pet, finished ones too; ones that left pop.
    pub fn sync(self: *Sim, entries: []const Entry, layout: Layout) void {
        for (&self.bodies) |*b| {
            if (!b.live()) continue;
            const e = find(entries, b.id) orelse {
                b.leaving = true;
                continue;
            };
            // A conversation that comes back mid-pop keeps its bubble.
            b.pop = 0;
            b.status = e.status;
            b.icon = e.icon;
            b.leaving = false;
        }
        for (entries) |e| {
            if (e.id == 0 or self.indexOf(e.id) != null) continue;
            const slot = self.free() orelse return;
            self.seq +%= 1;
            self.bodies[slot] = .{
                .id = e.id,
                .status = e.status,
                .icon = e.icon,
                .seq = self.seq,
                .x = layout.width / 2,
                .y = if (layout.flipped) margin + radius else layout.height - margin - radius,
                .vy = if (layout.flipped) rise_speed else -rise_speed,
            };
        }
    }

    pub fn step(self: *Sim, dt_in: f32, layout: Layout) void {
        // A taller window keeps its bottom on the pet: the cluster moves
        // with that edge instead of jumping away from it.
        if (self.height != layout.height) {
            if (!layout.flipped and self.height != 0) {
                for (&self.bodies) |*b| b.y += layout.height - self.height;
            }
            self.height = layout.height;
        }
        const dt = std.math.clamp(dt_in, 0, max_dt);
        if (dt == 0) return;
        self.t += dt;
        var homes: [capacity]Point = undefined;
        self.placeHomes(layout, &homes);
        for (&self.bodies, 0..) |*b, i| {
            if (!b.live()) continue;
            b.born = @min(1, b.born + dt / grow_s);
            const opening = b.id == self.open_id and b.staying();
            b.open = approach(b.open, if (opening) 1 else 0, dt / open_s);
            if (b.leaving) b.pop += dt / pop_s;
            if (b.pop >= 1) {
                b.* = .{};
                continue;
            }
            var home = homes[i];
            // The card holds still to be read, and so do resting bubbles.
            if (b.open == 0 and b.sways()) {
                const seed: f32 = @floatFromInt(b.id % 997);
                const period = 3 + @mod(seed, 20) / 10;
                const phase = seed * 0.37;
                home.x += drift_px * @sin(self.t * std.math.tau / period + phase);
                home.y += drift_px * @cos(self.t * std.math.tau / (period * 1.3) + phase);
            }
            b.vx += (home.x - b.x) * spring * dt;
            b.vy += (home.y - b.y) * spring * dt;
            const keep = @exp(-damping * dt);
            b.vx *= keep;
            b.vy *= keep;
            b.x += b.vx * dt;
            b.y += b.vy * dt;
        }
        if (self.open_id != 0 and self.openIndex() == null) self.open_id = 0;
        self.separate(layout);
        self.contain(layout);
    }

    /// Open a body as the card, or close it if it is the card already.
    pub fn toggle(self: *Sim, index: usize) void {
        if (index >= capacity) return;
        const b = self.bodies[index];
        if (!b.staying()) return;
        self.open_id = if (self.open_id == b.id) 0 else b.id;
    }

    /// The body under a window-local point: the card first, then the
    /// bubbles from the front (later slots draw on top).
    pub fn hit(self: *const Sim, layout: Layout, x: f32, y: f32) ?usize {
        if (self.openIndex()) |i| {
            if (inside(shape(self.bodies[i], layout), x, y)) return i;
        }
        var i: usize = capacity;
        while (i > 0) {
            i -= 1;
            const b = self.bodies[i];
            if (!b.staying()) continue;
            if (inside(shape(b, layout), x, y)) return i;
        }
        return null;
    }

    pub fn openIndex(self: *const Sim) ?usize {
        if (self.open_id == 0) return null;
        const i = self.indexOf(self.open_id) orelse return null;
        return if (self.bodies[i].staying()) i else null;
    }

    /// Bodies holding a place, which is what the window is sized for.
    pub fn stayingCount(self: *const Sim) usize {
        var n: usize = 0;
        for (self.bodies) |b| {
            if (b.staying()) n += 1;
        }
        return n;
    }

    /// Something still moves: a bubble that sways or waits (its light
    /// breathes), grows in, pops, opens or closes, or has not come to rest.
    /// When nothing does, the caller can stop stepping until something
    /// changes.
    pub fn restless(self: *const Sim) bool {
        for (self.bodies) |b| {
            if (!b.live()) continue;
            if (b.sways() or b.leaving or b.pop > 0 or b.born < 1) return true;
            const target: f32 = if (b.id == self.open_id) 1 else 0;
            if (b.open != target) return true;
            if (@abs(b.vx) > settle_speed or @abs(b.vy) > settle_speed) return true;
        }
        return false;
    }

    /// Anything still on screen, popping ones included.
    pub fn anyLive(self: *const Sim) bool {
        for (self.bodies) |b| {
            if (b.live()) return true;
        }
        return false;
    }

    pub fn clear(self: *Sim) void {
        self.* = .{ .seq = self.seq };
    }

    fn indexOf(self: *const Sim, id: u64) ?usize {
        if (id == 0) return null;
        for (self.bodies, 0..) |b, i| {
            if (b.id == id) return i;
        }
        return null;
    }

    fn free(self: *const Sim) ?usize {
        for (self.bodies, 0..) |b, i| {
            if (!b.live()) return i;
        }
        return null;
    }

    /// Every staying body's place, in arrival order: rows of `per_row`
    /// from the pet's side, centered. An open card takes the row by the
    /// pet; the first two others sit in the lanes beside it, the rest in
    /// rows beyond. Leaving bodies pop where they are.
    fn placeHomes(self: *const Sim, layout: Layout, out: *[capacity]Point) void {
        var order: [capacity]usize = undefined;
        var n: usize = 0;
        var open_index: ?usize = null;
        for (self.bodies, 0..) |b, i| {
            out[i] = .{ .x = b.x, .y = b.y };
            if (!b.staying()) continue;
            if (b.id == self.open_id) {
                open_index = i;
                continue;
            }
            var k = n;
            while (k > 0 and self.bodies[order[k - 1]].seq > b.seq) : (k -= 1) order[k] = order[k - 1];
            order[k] = i;
            n += 1;
        }
        // Rows grow away from the pet: up above it, down below it.
        const dir: f32 = if (layout.flipped) 1 else -1;
        const near_edge = if (layout.flipped) margin else layout.height - margin;
        var rest: []const usize = order[0..n];
        var first_y = near_edge + dir * radius;
        if (open_index) |oi| {
            const card_y = near_edge + dir * layout.card_h / 2;
            out[oi] = .{ .x = layout.width / 2, .y = card_y };
            const lane = (margin + (layout.width - layout.card_w) / 2 - spacing) / 2;
            const lanes = [_]f32{ lane, layout.width - lane };
            const beside = @min(rest.len, lanes.len);
            for (rest[0..beside], lanes[0..beside]) |i, x| out[i] = .{ .x = x, .y = card_y };
            rest = rest[beside..];
            first_y = near_edge + dir * (layout.card_h + gap + radius);
        }
        for (rest, 0..) |index, k| {
            const row = k / per_row;
            const in_row = @min(per_row, rest.len - row * per_row);
            const col: f32 = @floatFromInt(k % per_row);
            const centered = col - @as(f32, @floatFromInt(in_row - 1)) / 2;
            out[index] = .{
                .x = layout.width / 2 + centered * (diameter + gap),
                .y = first_y + dir * (diameter + gap) * @as(f32, @floatFromInt(row)),
            };
        }
    }

    /// Overlapping bubbles part; the card shoves and is never shoved.
    fn separate(self: *Sim, layout: Layout) void {
        for (0..capacity) |i| {
            if (!self.bodies[i].live()) continue;
            for (i + 1..capacity) |j| {
                if (!self.bodies[j].live()) continue;
                const a = &self.bodies[i];
                const b = &self.bodies[j];
                if (a.open > 0 or b.open > 0) {
                    const card_is_a = a.open >= b.open;
                    const card = if (card_is_a) a.* else b.*;
                    pushOut(if (card_is_a) b else a, shape(card, layout));
                    continue;
                }
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                const dist = @sqrt(dx * dx + dy * dy);
                const overlap = diameter + spacing - dist;
                if (overlap <= 0) continue;
                // Coincident centers part sideways, the same way every time.
                const nx = if (dist > 0.001) dx / dist else 1;
                const ny = if (dist > 0.001) dy / dist else 0;
                a.x -= nx * overlap / 2;
                a.y -= ny * overlap / 2;
                b.x += nx * overlap / 2;
                b.y += ny * overlap / 2;
                // Soak up the speed driving them together, so they settle
                // side by side instead of bouncing.
                const closing = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
                if (closing < 0) {
                    a.vx += nx * closing / 2;
                    a.vy += ny * closing / 2;
                    b.vx -= nx * closing / 2;
                    b.vy -= ny * closing / 2;
                }
            }
        }
    }

    fn contain(self: *Sim, layout: Layout) void {
        for (&self.bodies) |*b| {
            if (!b.live()) continue;
            const s = shape(b.*, layout);
            clampAxis(&b.x, &b.vx, margin + s.w / 2, layout.width - margin - s.w / 2);
            clampAxis(&b.y, &b.vy, margin + s.h / 2, layout.height - margin - s.h / 2);
        }
    }
};

fn find(entries: []const Entry, id: u64) ?Entry {
    for (entries) |e| {
        if (e.id == id) return e;
    }
    return null;
}

/// Push a bubble clear of the card's rect, and drop the part of its speed
/// heading back in.
fn pushOut(ball: *Body, card: Shape) void {
    const hw = card.w / 2 + spacing;
    const hh = card.h / 2 + spacing;
    const nearest_x = std.math.clamp(ball.x, card.x - hw, card.x + hw);
    const nearest_y = std.math.clamp(ball.y, card.y - hh, card.y + hh);
    const dx = ball.x - nearest_x;
    const dy = ball.y - nearest_y;
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist >= radius) return;
    if (dist < 0.001) {
        // The center is inside the card: leave by the nearest side.
        const left = ball.x - (card.x - hw);
        const right = card.x + hw - ball.x;
        const top = ball.y - (card.y - hh);
        const bottom = card.y + hh - ball.y;
        const least = @min(@min(left, right), @min(top, bottom));
        if (least == left) {
            ball.x = card.x - hw - radius;
        } else if (least == right) {
            ball.x = card.x + hw + radius;
        } else if (least == top) {
            ball.y = card.y - hh - radius;
        } else {
            ball.y = card.y + hh + radius;
        }
        return;
    }
    const nx = dx / dist;
    const ny = dy / dist;
    ball.x += nx * (radius - dist);
    ball.y += ny * (radius - dist);
    const inward = ball.vx * nx + ball.vy * ny;
    if (inward < 0) {
        ball.vx -= nx * inward;
        ball.vy -= ny * inward;
    }
}

fn clampAxis(pos: *f32, vel: *f32, lo: f32, hi: f32) void {
    if (lo > hi) {
        pos.* = (lo + hi) / 2;
        vel.* = 0;
    } else if (pos.* < lo) {
        pos.* = lo;
        if (vel.* < 0) vel.* = 0;
    } else if (pos.* > hi) {
        pos.* = hi;
        if (vel.* > 0) vel.* = 0;
    }
}

fn inside(s: Shape, x: f32, y: f32) bool {
    return @abs(x - s.x) <= s.w / 2 and @abs(y - s.y) <= s.h / 2;
}

fn approach(value: f32, target: f32, amount: f32) f32 {
    return if (value < target) @min(target, value + amount) else @max(target, value - amount);
}

fn lerp(a: f32, b: f32, f: f32) f32 {
    return a + (b - a) * f;
}

fn smooth(x: f32) f32 {
    return x * x * (3 - 2 * x);
}

fn easeOut(x: f32) f32 {
    const inv = 1 - x;
    return 1 - inv * inv * inv;
}

const t = std.testing;

const test_layout: Layout = .{
    .width = 364,
    .height = 150,
    .card_w = 260,
    .card_h = 62,
    .card_radius = 18,
};

fn run(sim: *Sim, entries: []const Entry, seconds: f32) void {
    var left = seconds;
    while (left > 0) : (left -= 1.0 / 30.0) {
        sim.sync(entries, test_layout);
        sim.step(1.0 / 30.0, test_layout);
    }
}

fn distance(a: Body, b: Body) f32 {
    return @sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
}

test "bubbles pushed onto each other part" {
    var sim: Sim = .{};
    const entries = [_]Entry{ .{ .id = 1, .status = .working }, .{ .id = 2, .status = .working } };
    run(&sim, &entries, 0.1);
    sim.bodies[1].x = sim.bodies[0].x;
    sim.bodies[1].y = sim.bodies[0].y;
    run(&sim, &entries, 2);
    try t.expect(distance(sim.bodies[0], sim.bodies[1]) >= diameter);
}

test "ten bubbles stay inside the window, however hard they are flung" {
    var sim: Sim = .{};
    var entries: [capacity]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .id = i + 1, .status = .working };
    run(&sim, &entries, 0.5);
    for (&sim.bodies, 0..) |*b, i| {
        b.vx = if (i % 2 == 0) 5000 else -5000;
        b.vy = -5000;
    }
    for (0..90) |_| {
        sim.step(1.0 / 30.0, test_layout);
        for (sim.bodies) |b| {
            try t.expect(b.x >= margin + radius - 0.01 and b.x <= test_layout.width - margin - radius + 0.01);
            try t.expect(b.y >= margin + radius - 0.01 and b.y <= test_layout.height - margin - radius + 0.01);
        }
    }
}

test "an open card pushes the other bubbles out of its way" {
    var sim: Sim = .{};
    var entries: [6]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .id = i + 1, .status = .working };
    const layout: Layout = .{ .width = test_layout.width, .height = contentHeight(6, true, 62), .card_w = 260, .card_h = 62, .card_radius = 18 };
    for (0..30) |_| {
        sim.sync(&entries, layout);
        sim.step(1.0 / 30.0, layout);
    }
    sim.toggle(2);
    try t.expectEqual(@as(?usize, 2), sim.openIndex());
    for (0..90) |_| {
        sim.sync(&entries, layout);
        sim.step(1.0 / 30.0, layout);
    }
    const card = shape(sim.bodies[2], layout);
    try t.expectEqual(@as(f32, 260), card.w);
    for (sim.bodies, 0..) |b, i| {
        if (i == 2 or !b.live()) continue;
        const clear_x = @abs(b.x - card.x) >= card.w / 2 + radius;
        const clear_y = @abs(b.y - card.y) >= card.h / 2 + radius;
        try t.expect(clear_x or clear_y);
    }
    sim.toggle(2);
    try t.expectEqual(@as(?usize, null), sim.openIndex());
}

test "a finished bubble stays and rests, and pops only when its conversation leaves" {
    var sim: Sim = .{};
    run(&sim, &.{.{ .id = 7, .status = .working }}, 0.5);
    try t.expectEqual(@as(f32, 1), sim.bodies[0].born);
    try t.expect(sim.restless());
    const done = [_]Entry{.{ .id = 7, .status = .done }};
    run(&sim, &done, 5);
    try t.expect(sim.bodies[0].live());
    try t.expectEqual(@as(f32, 0), sim.bodies[0].pop);
    // Nothing moves any more, so there is nothing to step.
    try t.expect(!sim.restless());
    // A conversation first seen finished still gets its bubble.
    run(&sim, &.{ .{ .id = 7, .status = .done }, .{ .id = 8, .status = .done } }, 0.2);
    try t.expect(sim.indexOf(8) != null);
    try t.expect(sim.restless());
    // Leaving pops it.
    run(&sim, &.{.{ .id = 8, .status = .done }}, 0.5);
    try t.expect(sim.indexOf(7) == null);
}

test "working and waiting bubbles keep the clock running" {
    var sim: Sim = .{};
    run(&sim, &.{.{ .id = 1, .status = .working }}, 5);
    try t.expect(sim.restless());
    run(&sim, &.{.{ .id = 1, .status = .waiting }}, 1);
    try t.expect(sim.restless());
    run(&sim, &.{.{ .id = 1, .status = .failed }}, 5);
    try t.expect(!sim.restless());
}

test "a conversation that leaves pops at once, and closes its card" {
    var sim: Sim = .{};
    run(&sim, &.{.{ .id = 3, .status = .waiting }}, 0.5);
    sim.toggle(0);
    try t.expect(sim.openIndex() != null);
    run(&sim, &.{}, 0.3);
    try t.expect(!sim.anyLive());
    try t.expectEqual(@as(u64, 0), sim.open_id);
}

test "a body keeps its slot when the list reorders" {
    var sim: Sim = .{};
    run(&sim, &.{ .{ .id = 10, .status = .working }, .{ .id = 20, .status = .waiting } }, 0.2);
    const before = sim.indexOf(20).?;
    run(&sim, &.{ .{ .id = 20, .status = .waiting }, .{ .id = 10, .status = .working } }, 0.2);
    try t.expectEqual(before, sim.indexOf(20).?);
    try t.expectEqual(Status.waiting, sim.bodies[before].status);
}

test "the same inputs give the same motion" {
    var a: Sim = .{};
    var b: Sim = .{};
    const entries = [_]Entry{ .{ .id = 1, .status = .working }, .{ .id = 2, .status = .failed }, .{ .id = 3, .status = .waiting } };
    run(&a, &entries, 2);
    run(&b, &entries, 2);
    try t.expect(std.meta.eql(a, b));
}

test "the window grows a row at a time, and by the card when one is open" {
    try t.expectEqual(2 * margin + diameter, contentHeight(0, false, 62));
    try t.expectEqual(contentHeight(1, false, 62), contentHeight(per_row, false, 62));
    try t.expect(contentHeight(per_row + 1, false, 62) > contentHeight(per_row, false, 62));
    // Open with two others: both fit beside the card.
    try t.expectEqual(2 * margin + 62, contentHeight(3, true, 62));
    try t.expect(contentHeight(4, true, 62) > contentHeight(3, true, 62));
    try t.expect(contentWidth(260) >= 260 + 2 * diameter);
}

test "a hit finds the bubble under the point, and nothing between them" {
    var sim: Sim = .{};
    run(&sim, &.{ .{ .id = 1, .status = .working }, .{ .id = 2, .status = .working } }, 2);
    const b = sim.bodies[1];
    try t.expectEqual(@as(?usize, 1), sim.hit(test_layout, b.x, b.y));
    try t.expectEqual(@as(?usize, null), sim.hit(test_layout, 1, 1));
}
