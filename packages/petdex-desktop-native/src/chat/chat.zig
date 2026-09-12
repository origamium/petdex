//! Pet chat core: domain types, the provider port and its adapters, the
//! session state machine, persona and config. Pure: nothing under
//! src/chat/ imports native_sdk or main.zig or touches the filesystem;
//! chat_shell.zig owns every effect. Keep it that way — it is what lets
//! all of this run under `native test` with no runtime.

pub const domain = @import("domain.zig");
pub const provider = @import("provider.zig");
pub const codex = @import("codex.zig");
pub const openai_compat = @import("openai_compat.zig");
pub const session = @import("session.zig");
pub const persona = @import("persona.zig");
pub const config = @import("config.zig");

test {
    _ = domain;
    _ = provider;
    _ = codex;
    _ = openai_compat;
    _ = session;
    _ = persona;
    _ = config;
}
