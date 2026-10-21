//! libzmx - Public programmatic interface for zmx.
const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const client = @import("client.zig");
const util = @import("util.zig");

pub const has_daemon = if (@hasDecl(build_options, "has_daemon")) build_options.has_daemon else true;

pub const ipc = @import("ipc.zig");

pub const HistoryFormat = util.HistoryFormat;
pub const SessionEntry = util.SessionEntry;

pub const CreateOptions = client.CreateOptions;
pub const AttachOptions = client.AttachOptions;
pub const RunOptions = client.RunOptions;
pub const KillOptions = client.KillOptions;
pub const KillStatus = client.KillStatus;

pub const connect = client.connect;
pub const attach = client.attach;
pub const detach = client.detach;
pub const list = client.list;
pub const kill = client.kill;
pub const run = client.run;
pub const wait = client.wait;
pub const tail = client.tail;
pub const send = client.send;
pub const print = client.print;
pub const write = client.write;
pub const history = client.history;
pub const historyRange = client.historyRange;
pub const get = client.get;
pub const set = client.set;
pub const clear = client.clear;
pub const printEnv = client.printEnv;

// Export create() when daemon is enabled, or provide compile error
pub const create = if (has_daemon) client.create else @compileError("create() requires -Ddaemon=true");
