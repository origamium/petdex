//! RFC 7636 PKCE material (verifier, S256 challenge) plus the OAuth
//! `state` nonce. Shared by the Petdex (Clerk) and ChatGPT sign-ins.

const std = @import("std");
const plat = @import("plat.zig");

const b64 = std.base64.url_safe_no_pad.Encoder;

/// base64url of 64 random bytes: the top of RFC 7636's 43..128 range.
pub const verifier_len = 86;
/// base64url of 32 random bytes.
pub const state_len = 43;
/// base64url of a SHA-256 digest.
pub const challenge_len = 43;

pub const Pkce = struct {
    verifier: [verifier_len]u8,
    state: [state_len]u8,
    challenge: [challenge_len]u8,
};

pub fn generate() ?Pkce {
    var verifier_raw: [64]u8 = undefined;
    var state_raw: [32]u8 = undefined;
    plat.fillRandom(&verifier_raw) catch return null;
    plat.fillRandom(&state_raw) catch return null;
    var p: Pkce = undefined;
    _ = b64.encode(&p.verifier, &verifier_raw);
    _ = b64.encode(&p.state, &state_raw);
    challengeFor(&p.verifier, &p.challenge);
    return p;
}

pub fn challengeFor(verifier: []const u8, out: *[challenge_len]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    _ = b64.encode(out, &digest);
}

test "S256 challenge matches RFC 7636 appendix B" {
    var out: [challenge_len]u8 = undefined;
    challengeFor("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", &out);
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &out);
}

test "generate yields fresh url-safe material with a matching challenge" {
    const a = generate().?;
    const b = generate().?;
    try std.testing.expect(!std.mem.eql(u8, &a.verifier, &b.verifier));
    try std.testing.expect(!std.mem.eql(u8, &a.state, &b.state));
    for (a.verifier ++ a.state) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
    var expected: [challenge_len]u8 = undefined;
    challengeFor(&a.verifier, &expected);
    try std.testing.expectEqualSlices(u8, &expected, &a.challenge);
}
