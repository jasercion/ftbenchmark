// src/fermi_binned_likelihood_benchmark.zig
// Zig program to run Fermi LAT Binned Likelihood Tutorial commands with benchmarking
// Tutorial: https://fermi.gsfc.nasa.gov/ssc/data/analysis/scitools/binned_likelihood_tutorial.html

const std = @import("std");
const fs = std.fs;
const process = std.process;
const mem = std.mem;
const fmt = std.fmt;
const http = std.http;

var app_io: std.Io = undefined;

/// Represents the result of a single command execution
const CommandResult = struct {
    name: []const u8,
    command: []const u8,
    exit_code: u8,
    duration_ns: i128,
    stdout_size: usize,
    stderr_size: usize,
    success: bool,
    error_message: ?[]const u8,
};

/// Configuration for the binned likelihood analysis
const Config = struct {
    // Data input path (directory containing input files)
    data_path: []const u8 = ".",

    // Data file names
    data_url: []const u8 = "https://fermi.gsfc.nasa.gov/ssc/data/analysis/scitools/data/BinnedLikelihood/",
    spacecraft_file: []const u8 = "L181126210218F4F0ED2738_SC00.fits",
    events_list: []const u8 = "binned_events.txt",
    filtered_file: []const u8 = "3C279_binned_filtered.fits",
    gti_file: []const u8 = "3C279_binned_gti.fits",
    cmap_file: []const u8 = "3C279_binned_cmap.fits",
    ccube_file: []const u8 = "3C279_binned_ccube.fits",
    ltcube_file: []const u8 = "3C279_binned_ltcube.fits",
    expcube_file: []const u8 = "3C279_binned_allsky_expcube.fits",
    srcmaps_file: []const u8 = "3C279_binned_srcmaps.fits",
    input_model: []const u8 = "3C279_input_model.xml",
    output_model: []const u8 = "3C279_binned_output.xml",
    catalog_file: []const u8 = "gll_psc_v32.xml",

    // Analysis parameters
    ra: f64 = 193.98,
    dec: f64 = -5.82,
    radius: f64 = 15.0,
    emin: f64 = 100.0,
    emax: f64 = 500000.0,
    zmax: f64 = 90.0,
    evclass: u32 = 128,
    evtype: u32 = 3,
    irfs: []const u8 = "P8R3_SOURCE_V3",

    // Binning parameters
    nxpix: u32 = 150,
    nypix: u32 = 150,
    binsz: f64 = 0.2,
    ebins: u32 = 37,
    coordsys: []const u8 = "CEL",
    proj: []const u8 = "AIT",

    // Livetime cube parameters
    dcostheta: f64 = 0.025,
    pixelsize: f64 = 1.0,

    // Exposure map parameters (all-sky)
    exp_nxpix: u32 = 1800,
    exp_nypix: u32 = 900,

    /// Get the full path to a file in the data directory
    pub fn getDataPath(self: Config, allocator: mem.Allocator, filename: []const u8) ![]const u8 {
        if (mem.eql(u8, self.data_path, ".")) {
            return try allocator.dupe(u8, filename);
        }
        return try fs.path.join(allocator, &.{ self.data_path, filename });
    }
};

/// Main benchmark runner
pub fn main(init: process.Init) !void {
    app_io = init.io;
    var allocator_state = std.heap.SafeAllocator.init(std.heap.page_allocator, .{});
    defer _ = allocator_state.deinit();
    const allocator = allocator_state.allocator();

    // Parse command line arguments
    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    var arg_iterator = process.Args.Iterator.init(init.minimal.args);
    while (arg_iterator.next()) |arg| {
        try args.append(arg);
    }

    var output_file: []const u8 = "benchmark_results.txt";
    var dry_run = false;
    var verbose = false;
    var data_path: []const u8 = ".";

    var i: usize = 1;
    while (i < args.items.len) : (i += 1) {
        if (mem.eql(u8, args.items[i], "--output") or mem.eql(u8, args.items[i], "-o")) {
            i += 1;
            if (i < args.items.len) {
                output_file = args.items[i];
            }
        } else if (mem.eql(u8, args.items[i], "--data-path") or mem.eql(u8, args.items[i], "-d")) {
            i += 1;
            if (i < args.items.len) {
                data_path = args.items[i];
            }
        } else if (mem.eql(u8, args.items[i], "--dry-run")) {
            dry_run = true;
        } else if (mem.eql(u8, args.items[i], "--verbose") or mem.eql(u8, args.items[i], "-v")) {
            verbose = true;
        } else if (mem.eql(u8, args.items[i], "--help") or mem.eql(u8, args.items[i], "-h")) {
            try printUsage();
            return;
        }
    }

    // Validate data path exists
    if (!mem.eql(u8, data_path, ".")) {
        std.Io.Dir.cwd().access(app_io, data_path, .{}) catch |err| {
            var buffer: [4096]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(app_io, &buffer);
            try stderr.interface.print("Error: Data path '{s}' is not accessible: {s}\n", .{ data_path, @errorName(err) });
            try stderr.interface.flush();
            return;
        };
    }

    var config = Config{
        .data_path = data_path,
    };
    _ = &config;

    // Download missing data files
    try downloadMissingDataFiles(&config, allocator);

    var results = std.array_list.Managed(CommandResult).init(allocator);
    defer results.deinit();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(app_io, &stdout_buffer);

    try stdout.interface.print(
        \\===============================================================
        \\  Fermi LAT Binned Likelihood Tutorial - Benchmark Runner
        \\===============================================================
        \\
        \\Configuration:
        \\  Data Path: {s}
        \\  RA: {d:.2}, DEC: {d:.2}, Radius: {d:.1} deg
        \\  Energy: {d:.0} - {d:.0} MeV
        \\  IRFs: {s}
        \\  Output: {s}
        \\  Dry Run: {}
        \\
        \\
    , .{
        config.data_path,
        config.ra,
        config.dec,
        config.radius,
        config.emin,
        config.emax,
        config.irfs,
        output_file,
        dry_run,
    });
    try stdout.interface.flush();

    // Build all commands
    const commands = try buildCommands(allocator, config);
    defer {
        for (commands) |cmd| {
            allocator.free(cmd.command);
        }
        allocator.free(commands);
    }

    // Execute commands
    const total_start: i128 = @intCast(std.Io.Clock.now(.awake, app_io).nanoseconds);

    for (commands, 0..) |cmd, idx| {
        try stdout.interface.print("\n[{}/{}] Running: {s}\n", .{ idx + 1, commands.len, cmd.name });
        if (verbose) {
            try stdout.interface.print("  Command: {s}\n", .{cmd.command});
        }

        const result = if (dry_run)
            createDryRunResult(cmd.name, cmd.command)
        else
            executeCommand(allocator, cmd.name, cmd.command);

        try results.append(result);

        if (result.success) {
            const duration_ms = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000.0;
            try stdout.interface.print("  ✓ Completed in {d:.2} ms\n", .{duration_ms});
        } else {
            try stdout.interface.print("  ✗ Failed: {s}\n", .{result.error_message orelse "Unknown error"});
        }
    }

    const total_end: i128 = @intCast(std.Io.Clock.now(.awake, app_io).nanoseconds);
    const total_duration_ns = total_end - total_start;

    // Write results to file
    try writeResults(allocator, output_file, results.items, total_duration_ns, config);

    try stdout.interface.print(
        \\
        \\===============================================================
        \\  Benchmark Complete
        \\===============================================================
        \\  Total Duration: {d:.2} seconds
        \\  Commands Executed: {}
        \\  Successful: {}
        \\  Failed: {}
        \\  Results written to: {s}
        \\===============================================================
        \\
    , .{
        @as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0,
        results.items.len,
        countSuccessful(results.items),
        results.items.len - countSuccessful(results.items),
        output_file,
    });
    try stdout.interface.flush();
}

fn printUsage() !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(app_io, &buffer);
    try stdout.interface.print(
        \\Fermi LAT Binned Likelihood Tutorial - Benchmark Runner
        \\
        \\Usage: fermi_benchmark [OPTIONS]
        \\
        \\Options:
        \\  -d, --data-path <DIR> Directory containing input data files (default: current directory)
        \\  -o, --output <FILE>   Output file for benchmark results (default: benchmark_results.txt)
        \\  --dry-run             Print commands without executing them
        \\  -v, --verbose         Show detailed command output
        \\  -h, --help            Show this help message
        \\
        \\Requirements:
        \\  - Fermitools must be installed and configured
        \\  - Required data files must be in the data path directory:
        \\      * L181126210218F4F0ED2738_PH*.fits (photon event files)
        \\      * L181126210218F4F0ED2738_SC00.fits (spacecraft file)
        \\      * gll_psc_v32.xml (LAT catalog file)
        \\
        \\Example:
        \\  fermi_benchmark --data-path /path/to/fermi/data --output results.txt
        \\  fermi_benchmark -d ~/fermi_data -v --dry-run
        \\
    , .{});
}

/// Command definition for building shell commands
const CommandDef = struct {
    name: []const u8,
    command: []const u8,
};

/// Build all analysis commands based on configuration
fn buildCommands(allocator: mem.Allocator, config: Config) ![]CommandDef {
    var commands = std.array_list.Managed(CommandDef).init(allocator);

    // Get full paths for input files
    const spacecraft_path = try config.getDataPath(allocator, config.spacecraft_file);
    defer allocator.free(spacecraft_path);

    const catalog_path = try config.getDataPath(allocator, config.catalog_file);
    defer allocator.free(catalog_path);

    // 1. Create events list file (if needed)
    // Use the data path for finding photon files
    if (mem.eql(u8, config.data_path, ".")) {
        try commands.append(.{
            .name = "Create events list",
            .command = try fmt.allocPrint(allocator, "ls *_PH*.fits > {s}", .{config.events_list}),
        });
    } else {
        try commands.append(.{
            .name = "Create events list",
            .command = try fmt.allocPrint(allocator, "ls {s}/*_PH*.fits > {s}", .{ config.data_path, config.events_list }),
        });
    }

    // 2. gtselect - Filter events
    try commands.append(.{
        .name = "gtselect - Filter events",
        .command = try fmt.allocPrint(allocator,
            \\gtselect infile=@{s} outfile={s} \
            \\  ra={d:.4} dec={d:.4} rad={d:.1} \
            \\  tmin=INDEF tmax=INDEF \
            \\  emin={d:.0} emax={d:.0} zmax={d:.0} \
            \\  evclass={} evtype={}
        , .{
            config.events_list,
            config.filtered_file,
            config.ra,
            config.dec,
            config.radius,
            config.emin,
            config.emax,
            config.zmax,
            config.evclass,
            config.evtype,
        }),
    });

    // 3. gtmktime - Apply GTI filter
    try commands.append(.{
        .name = "gtmktime - Apply GTI filter",
        .command = try fmt.allocPrint(allocator,
            \\gtmktime scfile={s} \
            \\  filter="(DATA_QUAL>0)&&(LAT_CONFIG==1)" \
            \\  roicut=no \
            \\  evfile={s} \
            \\  outfile={s}
        , .{
            spacecraft_path,
            config.filtered_file,
            config.gti_file,
        }),
    });

    // 4. gtbin CMAP - Create 2D counts map (sanity check)
    try commands.append(.{
        .name = "gtbin CMAP - Create counts map",
        .command = try fmt.allocPrint(allocator,
            \\gtbin algorithm=CMAP \
            \\  evfile={s} outfile={s} scfile=NONE \
            \\  nxpix={} nypix={} binsz={d:.2} \
            \\  coordsys={s} xref={d:.4} yref={d:.4} \
            \\  axisrot=0 proj={s}
        , .{
            config.gti_file,
            config.cmap_file,
            config.nxpix,
            config.nypix,
            config.binsz,
            config.coordsys,
            config.ra,
            config.dec,
            config.proj,
        }),
    });

    // 5. gtbin CCUBE - Create 3D counts cube
    try commands.append(.{
        .name = "gtbin CCUBE - Create counts cube",
        .command = try fmt.allocPrint(allocator,
            \\gtbin algorithm=CCUBE \
            \\  evfile={s} outfile={s} scfile=NONE \
            \\  nxpix={} nypix={} binsz={d:.2} \
            \\  coordsys={s} xref={d:.4} yref={d:.4} \
            \\  axisrot=0 proj={s} \
            \\  ebinalg=LOG emin={d:.0} emax={d:.0} enumbins={}
        , .{
            config.gti_file,
            config.ccube_file,
            config.nxpix,
            config.nypix,
            config.binsz,
            config.coordsys,
            config.ra,
            config.dec,
            config.proj,
            config.emin,
            config.emax,
            config.ebins,
        }),
    });

    // 6. make4FGLxml - Create source model (requires LATSourceModel package)
    // try commands.append(.{
    //     .name = "python scripts/make4FGLxml - Create source model",
    //     .command = try fmt.allocPrint(allocator,
    //         \\make4FGLxml {s} --event_file {s} \
    //         \\  --output_name {s} \
    //         \\  --free_radius 5.0 --norms_free_only True \
    //         \\  --sigma_to_free 25 --variable_free True
    //     , .{
    //         catalog_path,
    //         config.gti_file,
    //         config.input_model,
    //     }),
    // });

    // 7. gtltcube - Compute livetime cube
    try commands.append(.{
        .name = "gtltcube - Compute livetime cube",
        .command = try fmt.allocPrint(allocator,
            \\gtltcube zmax={d:.0} \
            \\  evfile={s} scfile={s} \
            \\  outfile={s} \
            \\  dcostheta={d:.3} binsz={d:.1}
        , .{
            config.zmax,
            config.gti_file,
            spacecraft_path,
            config.ltcube_file,
            config.dcostheta,
            config.pixelsize,
        }),
    });

    // 8. gtexpcube2 - Compute all-sky exposure map
    try commands.append(.{
        .name = "gtexpcube2 - Compute exposure map",
        .command = try fmt.allocPrint(allocator,
            \\gtexpcube2 infile={s} cmap=none \
            \\  outfile={s} irfs={s} \
            \\  nxpix={} nypix={} binsz={d:.2} \
            \\  coordsys={s} xref={d:.4} yref={d:.4} \
            \\  axisrot=0 proj={s} \
            \\  emin={d:.0} emax={d:.0} enumbins={}
        , .{
            config.ltcube_file,
            config.expcube_file,
            config.irfs,
            config.exp_nxpix,
            config.exp_nypix,
            config.binsz,
            config.coordsys,
            config.ra,
            config.dec,
            config.proj,
            config.emin,
            config.emax,
            config.ebins,
        }),
    });

    // 9. gtsrcmaps - Compute source maps
    try commands.append(.{
        .name = "gtsrcmaps - Compute source maps",
        .command = try fmt.allocPrint(allocator,
            \\gtsrcmaps expcube={s} \
            \\  cmap={s} \
            \\  srcmdl={s} \
            \\  bexpmap={s} \
            \\  outfile={s} \
            \\  irfs=CALDB
        , .{
            config.ltcube_file,
            config.ccube_file,
            config.input_model,
            config.expcube_file,
            config.srcmaps_file,
        }),
    });

    // 10. gtlike - Perform likelihood fit
    try commands.append(.{
        .name = "gtlike - Perform likelihood fit",
        .command = try fmt.allocPrint(allocator,
            \\gtlike refit=no plot=no \
            \\  statistic=BINNED \
            \\  cmap={s} \
            \\  bexpmap={s} \
            \\  expcube={s} \
            \\  srcmdl={s} \
            \\  sfile={s} \
            \\  irfs=CALDB \
            \\  optimizer=NEWMINUIT
        , .{
            config.srcmaps_file,
            config.expcube_file,
            config.ltcube_file,
            config.input_model,
            config.output_model,
        }),
    });

    return commands.toOwnedSlice();
}

/// Execute a shell command and return its result.
fn executeCommand(allocator: mem.Allocator, name: []const u8, command: []const u8) CommandResult {
    const start_time: i128 = @intCast(std.Io.Clock.now(.awake, app_io).nanoseconds);
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", command };

    const result = std.process.run(allocator, app_io, .{ .argv = argv }) catch |err| {
        const end_time: i128 = @intCast(std.Io.Clock.now(.awake, app_io).nanoseconds);
        return CommandResult{
            .name = name,
            .command = command,
            .exit_code = 255,
            .duration_ns = end_time - start_time,
            .stdout_size = 0,
            .stderr_size = 0,
            .success = false,
            .error_message = @errorName(err),
        };
    };

    const end_time: i128 = @intCast(std.Io.Clock.now(.awake, app_io).nanoseconds);

    const exit_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };

    const command_result = CommandResult{
        .name = name,
        .command = command,
        .exit_code = exit_code,
        .duration_ns = end_time - start_time,
        .stdout_size = result.stdout.len,
        .stderr_size = result.stderr.len,
        .success = exit_code == 0,
        .error_message = if (exit_code != 0) "Non-zero exit code" else null,
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return command_result;
}

/// Download missing data files function and http requester
fn downloadMissingDataFiles(config: *Config, allocator: mem.Allocator) !void {
    const data_files = [_][]const u8{ config.spacecraft_file, config.input_model, config.catalog_file };

    for (data_files) |filename| {
        const local_path = try config.getDataPath(allocator, filename);
        defer allocator.free(local_path);

        const file_exists = blk: {
            std.Io.Dir.cwd().access(app_io, local_path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    break :blk false;
                }
                return err;
            };
            break :blk true;
        };

        if (!file_exists) {
            std.debug.print("Downloading missing file: {s}\n", .{filename});

            const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.data_url, filename });
            defer allocator.free(url);

            try downloadFile(allocator, url, local_path);

            std.debug.print("Successfully downloaded: {s}\n", .{filename});
        } else {
            std.debug.print("File exists {s}\n", .{filename});
        }
    }
}

fn downloadFile(allocator: mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    std.debug.print("Downloading: {s}\n", .{url});

    // Try curl first
    if (runDownloadCommand(allocator, &[_][]const u8{ "curl", "-L", "-f", "-s", "-o", dest_path, url })) |_| {
        return;
    } else |_| {
        // Fall back to wget
        const result = try std.process.run(allocator, app_io, .{
            .argv = &[_][]const u8{ "wget", "-q", "-O", dest_path, url },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (!result.term.success()) {
            std.debug.print("Download failed. stderr: {s}\n", .{result.stderr});
            return error.DownloadFailed;
        }
    }
}

fn runDownloadCommand(allocator: mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, app_io, .{
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.term.success()) {
        return error.CommandFailed;
    }
}

/// Create a dry-run result (no actual execution)
fn createDryRunResult(name: []const u8, command: []const u8) CommandResult {
    return CommandResult{
        .name = name,
        .command = command,
        .exit_code = 0,
        .duration_ns = 0,
        .stdout_size = 0,
        .stderr_size = 0,
        .success = true,
        .error_message = null,
    };
}

/// Write benchmark results to file
fn writeResults(
    allocator: mem.Allocator,
    filename: []const u8,
    results: []const CommandResult,
    total_duration_ns: i128,
    config: Config,
) !void {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(app_io, filename, .{});
    defer file.close(app_io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(app_io, &buffer);

    // Write header
    try writer.interface.print(
        \\================================================================================
        \\  FERMI LAT BINNED LIKELIHOOD TUTORIAL - BENCHMARK RESULTS
        \\================================================================================
        \\
        \\Tutorial: https://fermi.gsfc.nasa.gov/ssc/data/analysis/scitools/binned_likelihood_tutorial.html
        \\
        \\Configuration:
        \\  Data Path:   {s}
        \\  RA, DEC:     {d:.4}, {d:.4}
        \\  Radius:      {d:.1} degrees
        \\  Energy:      {d:.0} - {d:.0} MeV
        \\  IRFs:        {s}
        \\  Event Class: {}
        \\  Event Type:  {}
        \\  Zenith Max:  {d:.0} degrees
        \\
        \\================================================================================
        \\  INDIVIDUAL COMMAND RESULTS
        \\================================================================================
        \\
    , .{
        config.data_path,
        config.ra,
        config.dec,
        config.radius,
        config.emin,
        config.emax,
        config.irfs,
        config.evclass,
        config.evtype,
        config.zmax,
    });

    // Write individual results
    var total_successful: usize = 0;
    var total_command_time: i128 = 0;

    for (results, 0..) |result, idx| {
        const duration_sec = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000_000.0;
        total_command_time += result.duration_ns;

        const status = if (result.success) "SUCCESS" else "FAILED";
        if (result.success) total_successful += 1;

        try writer.interface.print(
            \\
            \\Step {}: {s}
            \\  Status:      {s}
            \\  Exit Code:   {}
            \\  Duration:    {d:.3} seconds
            \\  Stdout Size: {} bytes
            \\  Stderr Size: {} bytes
            \\  Command:
            \\    {s}
            \\
        , .{
            idx + 1,
            result.name,
            status,
            result.exit_code,
            duration_sec,
            result.stdout_size,
            result.stderr_size,
            result.command,
        });

        if (result.error_message) |msg| {
            try writer.interface.print("  Error:       {s}\n", .{msg});
        }
    }

    // Write summary
    const total_sec = @as(f64, @floatFromInt(total_duration_ns)) / 1_000_000_000.0;
    const cmd_time_sec = @as(f64, @floatFromInt(total_command_time)) / 1_000_000_000.0;

    try writer.interface.print(
        \\
        \\================================================================================
        \\  SUMMARY
        \\================================================================================
        \\
        \\Total Commands:    {}
        \\Successful:        {}
        \\Failed:            {}
        \\Success Rate:      {d:.1}%
        \\
        \\Command Time:      {d:.3} seconds
        \\Total Wall Time:   {d:.3} seconds
        \\Overhead:          {d:.3} seconds
        \\
        \\================================================================================
        \\  TIMING BREAKDOWN
        \\================================================================================
        \\
    , .{
        results.len,
        total_successful,
        results.len - total_successful,
        if (results.len > 0) @as(f64, @floatFromInt(total_successful)) / @as(f64, @floatFromInt(results.len)) * 100.0 else 0.0,
        cmd_time_sec,
        total_sec,
        total_sec - cmd_time_sec,
    });

    // Write table header
    try writer.interface.print("{s:<6} {s:<40} {s:<12} {s:<10}\n", .{ "Step", "Command", "Time (s)", "% Total" });
    try writer.interface.print("{s}\n", .{"----------------------------------------------------------------------"});

    // Timing breakdown table
    for (results, 0..) |result, idx| {
        const duration_sec = @as(f64, @floatFromInt(result.duration_ns)) / 1_000_000_000.0;
        const percent = if (total_command_time > 0)
            @as(f64, @floatFromInt(result.duration_ns)) / @as(f64, @floatFromInt(total_command_time)) * 100.0
        else
            0.0;

        // Truncate name if too long
        var name_buf: [40]u8 = undefined;
        const display_name: []const u8 = if (result.name.len > 38) blk: {
            @memcpy(name_buf[0..37], result.name[0..37]);
            name_buf[37] = '.';
            name_buf[38] = '.';
            name_buf[39] = '.';
            break :blk name_buf[0..40];
        } else result.name;

        try writer.interface.print("{:<6} {s:<40} {d:<12.3} {d:<10.1}\n", .{
            idx + 1,
            display_name,
            duration_sec,
            percent,
        });
    }

    try writer.interface.print("{s}\n", .{"----------------------------------------------------------------------"});
    try writer.interface.print("{s:<6} {s:<40} {d:<12.3} {s:<10}\n", .{ "TOTAL", "", cmd_time_sec, "100.0" });

    try writer.interface.print(
        \\
        \\================================================================================
        \\  END OF REPORT
        \\================================================================================
        \\
    , .{});
    try writer.interface.flush();
}

/// Count successful commands
fn countSuccessful(results: []const CommandResult) usize {
    var count: usize = 0;
    for (results) |r| {
        if (r.success) count += 1;
    }
    return count;
}

test "command building" {
    const allocator = std.testing.allocator;
    const config = Config{};

    const commands = try buildCommands(allocator, config);
    defer {
        for (commands) |cmd| {
            allocator.free(cmd.command);
        }
        allocator.free(commands);
    }

    try std.testing.expect(commands.len == 9);
}

test "config getDataPath" {
    const allocator = std.testing.allocator;

    // Test with default path
    const config1 = Config{};
    const path1 = try config1.getDataPath(allocator, "test.fits");
    defer allocator.free(path1);
    try std.testing.expectEqualStrings("test.fits", path1);

    // Test with custom path
    const config2 = Config{ .data_path = "/data/fermi" };
    const path2 = try config2.getDataPath(allocator, "test.fits");
    defer allocator.free(path2);
    try std.testing.expectEqualStrings("/data/fermi/test.fits", path2);
}
