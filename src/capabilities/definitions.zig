//! Capability definitions supplied with zmx.
//! The registry uses this catalog to provide required behavior and look up optional
//! capability names. Applications embedding libzmx can select these optional
//! definitions or supply their own compiled modules through the same API.
//!
//! For example, add Program Status to a new session
//!
//! ```zig
//! const zmx = @import("zmx");
//! _ = try zmx.create(gpa, io, "agent", .{
//!     .optional_capabilities = &.{zmx.capability_definitions.program_status},
//! });
//! ```
//! Always-active capabilities are included automatically. Do not add them again.
pub const working_directory = @import("working_directory/main.zig").definition;
pub const program_status = @import("program_status/main.zig").definition;
