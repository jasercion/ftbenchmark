const std = @import("std");
const benchmark = @import("fermitools_benchmark.zig");

pub fn appendCommands(
    allocator: std.mem.Allocator,
    commands: *std.array_list.Managed(benchmark.CommandDef),
    config: benchmark.Config,
) !void {
    _ = config;

    try commands.append(.{
        .name = "Example extra command",
        .command = try std.fmt.allocPrint(allocator, "echo extra command", .{}),
    });
}