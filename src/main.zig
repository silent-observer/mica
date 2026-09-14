//! The `mica` command line tool. Only `route` exists so far, because routing is
//! the only pass wired up end to end - there is still no lowering to a
//! `Configuration`, so the netlist and bitstream halves of `core` never meet.

const std = @import("std");
const Io = std.Io;

const core = @import("core");
const Router = @import("router");

const Netlist = core.Netlist;

const usage =
    \\Usage: mica <command> [options]
    \\
    \\Commands:
    \\  route <input.mnl> [-o <output.mnl>]
    \\      Route a placed netlist. Any routes the input already carries are
    \\      discarded and searched for again. The default output name is the
    \\      input with its extension replaced by ".routed.mnl".
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2)
        fail("expected a command\n\n{s}", .{usage});

    const command = args[1];
    if (std.mem.eql(u8, command, "route"))
        return routeCommand(init, args[2..]);

    fail("unknown command '{s}'\n\n{s}", .{ command, usage });
}

/// Reports a usage or I/O problem and stops. Diagnostics from the netlist
/// itself - parse errors, validation errors - go through here too, so that a
/// malformed input never reaches the panicking parts of the router.
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mica: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn routeCommand(init: std.process.Init, args: []const [:0]const u8) !void {
    var input: ?[]const u8 = null;
    var output: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i == args.len)
                fail("-o expects a file name", .{});
            if (output != null)
                fail("-o given more than once", .{});
            output = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fail("unknown option '{s}'\n\n{s}", .{ arg, usage });
        } else if (input == null) {
            input = arg;
        } else {
            fail("route takes one input netlist, got '{s}' as well", .{arg});
        }
    }

    const in_path = input orelse fail("route expects an input netlist\n\n{s}", .{usage});
    const out_path = output orelse defaultOutputPath(init.arena.allocator(), in_path);

    const gpa = init.gpa;

    const text = Io.Dir.cwd().readFileAlloc(init.io, in_path, gpa, .unlimited) catch |e|
        fail("cannot read '{s}': {t}", .{ in_path, e });
    defer gpa.free(text);

    const parsed = core.NetlistParser.parse(text, gpa);
    defer parsed.deinit(gpa);

    if (parsed.err) |e|
        fail("{s}: {s}", .{ in_path, e });
    const nl = parsed.netlist.?;

    // `Netlist.validate` is still a stub, but the little it checks runs on both
    // sides of the router: before, because the router asserts rather than
    // diagnoses the properties it assumes, and after, because rerouting must not
    // have changed what the netlist says about its nets. Inputs the stub does
    // not cover yet can still panic in the router; that is expected for now.
    validate(nl, gpa, in_path, "before routing");

    // The router appends to `route_edges` and expects each net's span to be the
    // one it is growing, so an already-routed input has to be stripped first.
    for (nl.nets.items) |*net| {
        net.route_start = 0;
        net.route_len = 0;
    }
    nl.route_edges.clearRetainingCapacity();

    Router.route(nl, gpa);

    validate(nl, gpa, in_path, "after routing");

    const emitted = core.NetlistEmitter.emit(nl, gpa);
    defer emitted.deinit(gpa);

    for (emitted.warnings) |warning|
        std.debug.print("mica: warning: {s}\n", .{warning});

    Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = out_path,
        .data = emitted.text,
    }) catch |e| fail("cannot write '{s}': {t}", .{ out_path, e });

    std.debug.print("mica: wrote {s}\n", .{out_path});
}

/// `foo.mnl` -> `foo.routed.mnl`. A name that is not a netlist keeps its
/// extension and gains the suffix, so the command never writes over its input
/// unless `-o` says to.
fn defaultOutputPath(arena: std.mem.Allocator, input: []const u8) []const u8 {
    const stem = if (std.mem.endsWith(u8, input, ".mnl"))
        input[0 .. input.len - ".mnl".len]
    else
        input;
    return std.fmt.allocPrint(arena, "{s}.routed.mnl", .{stem}) catch core.common.oom();
}

fn validate(
    nl: *const Netlist,
    gpa: std.mem.Allocator,
    path: []const u8,
    when: []const u8,
) void {
    var result = Netlist.validate(nl, gpa);
    defer {
        result.errs.deinit();
        result.str_arena.deinit();
    }

    if (result.errs.items.len == 0) return;

    for (result.errs.items) |e|
        std.debug.print("mica: {s}: {s} {s}\n", .{ path, when, e });
    fail("{} validation error(s) {s}", .{ result.errs.items.len, when });
}
