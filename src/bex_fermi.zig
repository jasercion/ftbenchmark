const std = @import("std");
const benchmark = @import("fermitools_benchmark.zig");

const mem = std.mem;
const fmt = std.fmt;

/// Configuration options specific to BEX Fermi aperture photometry & probability analysis.
pub const BexConfig = struct {
    // Source identification & position
    source_name: []const u8 = "3C279",
    target_name: []const u8 = "_3C279",
    ra: f64 = 193.98,
    dec: f64 = -5.82,

    // File names & lists
    ft1_list: []const u8 = "plist.dat",
    spacecraft_file: []const u8 = "lat_spacecraft_merged.fits",
    catalog_file: []const u8 = "gll_psc_v40.fit",
    input_model: []const u8 = "bex_LATxmlmodel.xml",

    // Intermediate and output files
    eventfile_raw: []const u8 = "bex_eventfile0.0.fits",
    eventfile_filtered: []const u8 = "bex_eventfile0.fits",
    eventfile_cut: []const u8 = "bex_temp2.fits",
    eventfile_gti: []const u8 = "bex_temp3.fits",
    eventfile_prob: []const u8 = "bex_eventfile2.fits",
    lc_file: []const u8 = "lc_bex.fits",
    lc_bary_file: []const u8 = "lc_bex_bary.fits",

    // Time & binning parameters
    bin_size: f64 = 500.0,
    tmin: f64 = 0.0,
    tmax: f64 = 0.0,

    // Aperture & energy parameters
    roi: f64 = 3.0,
    roi_inner: f64 = 0.0,
    emin: f64 = 100.0,
    emax: f64 = 500000.0,

    // Filtering constraints
    zenith_limit: f64 = 105.0,
    rock: f64 = 90.0,
    bore: f64 = 180.0,
    sun_minimum: f64 = 5.0,
    spectral_index: f64 = -2.1,

    // IRF & Event selection
    irf_code: u32 = 9,
    irfs: []const u8 = "CALDB",
    evclass: u32 = 128,
    evtype: u32 = 3,

    // Pipeline feature flags
    use_probability: bool = true,
    dodiffuse: bool = false,
    barycenter: bool = true,
};

/// Append the Fermi LAT BEX (probability-weighted aperture photometry) commands.
/// Compatible with benchmark.Config and the fermitools_benchmark command set interface.
pub fn appendCommands(
    allocator: mem.Allocator,
    commands: *std.array_list.Managed(benchmark.CommandDef),
    config: benchmark.Config,
) !void {
    const bex_config = BexConfig{
        .ra = config.ra,
        .dec = config.dec,
        .roi = config.radius,
        .emin = config.emin,
        .emax = config.emax,
        .zenith_limit = config.zmax,
        .evclass = config.evclass,
        .evtype = config.evtype,
        .irfs = config.irfs,
        .spacecraft_file = config.spacecraft_file,
        .catalog_file = config.catalog_file,
        .input_model = config.input_model,
    };

    try appendBexCommands(allocator, commands, config, bex_config);
}

/// Append BEX Fermi pipeline commands with explicit BexConfig settings.
pub fn appendBexCommands(
    allocator: mem.Allocator,
    commands: *std.array_list.Managed(benchmark.CommandDef),
    config: benchmark.Config,
    bex: BexConfig,
) !void {
    const spacecraft_path = try config.getDataPath(allocator, bex.spacecraft_file);
    defer allocator.free(spacecraft_path);

    const inputmodel_path = try config.getDataPath(allocator, bex.input_model);
    defer allocator.free(inputmodel_path);

    // 1. Create photon file list (if needed)
    if (mem.eql(u8, config.data_path, ".")) {
        try commands.append(.{
            .name = "Create photon events list",
            .command = try fmt.allocPrint(allocator, "ls *_PH*.fits > {s}", .{bex.ft1_list}),
        });
    } else {
        try commands.append(.{
            .name = "Create photon events list",
            .command = try fmt.allocPrint(allocator, "ls {s}/*_PH*.fits > {s}", .{ config.data_path, bex.ft1_list }),
        });
    }

    // 2. gtselect - Initial ROI and energy selection
    try commands.append(.{
        .name = "gtselect - Initial selection",
        .command = try fmt.allocPrint(allocator,
            \\gtselect chatter=2 \
            \\  infile=@{s} outfile={s} \
            \\  ra={d:.4} dec={d:.4} rad={d:.1} \
            \\  tmin=0 tmax=0 \
            \\  emin={d:.0} emax={d:.0} zmax=180 \
            \\  evclass={} evtype={}
            , .{
                bex.ft1_list,
                bex.eventfile_raw,
                bex.ra,
                bex.dec,
                bex.roi,
                bex.emin,
                bex.emax,
                bex.evclass,
                bex.evtype,
            }),
    });

    // Optional annulus selection with fselect
    const selected_ft1 = if (bex.roi_inner > 0) blk: {
        try commands.append(.{
            .name = "fselect - Annulus selection",
            .command = try fmt.allocPrint(allocator,
                \\fselect infile={s} outfile={s} \
                \\  expr="circle({d:.4},{d:.4},{d:.1},RA,DEC) && !circle({d:.4},{d:.4},{d:.1},RA,DEC)"
                , .{
                    bex.eventfile_raw,
                    bex.eventfile_filtered,
                    bex.ra,
                    bex.dec,
                    bex.roi,
                    bex.ra,
                    bex.dec,
                    bex.roi_inner,
                }),
        });
        break :blk bex.eventfile_filtered;
    } else bex.eventfile_raw;

    // 3. gtselect - Time and zenith cuts
    try commands.append(.{
        .name = "gtselect - Time and zenith cuts",
        .command = try fmt.allocPrint(allocator,
            \\gtselect chatter=2 \
            \\  infile={s} outfile={s} \
            \\  ra={d:.4} dec={d:.4} rad={d:.1} \
            \\  tmin={d:.1} tmax={d:.1} \
            \\  emin={d:.0} emax={d:.0} zmax={d:.0} \
            \\  evclass={} evtype={}
            , .{
                selected_ft1,
                bex.eventfile_cut,
                bex.ra,
                bex.dec,
                bex.roi,
                bex.tmin,
                bex.tmax,
                bex.emin,
                bex.emax,
                bex.zenith_limit,
                bex.evclass,
                bex.evtype,
            }),
    });

    // 4. gtmktime - Apply GTI, rock angle, zenith, sun, and boresight filters
    try commands.append(.{
        .name = "gtmktime - Apply GTI and pointing filters",
        .command = try fmt.allocPrint(allocator,
            \\gtmktime chatter=2 scfile={s} \
            \\  filter="(DATA_QUAL>0) && ABS(ROCK_ANGLE)<{d:.0} && (LAT_CONFIG==1) && (angsep(RA_ZENITH,DEC_ZENITH,{d:.4},{d:.4})+{d:.1}<{d:.0}) && (angsep({d:.4},{d:.4},RA_SUN,DEC_SUN)>{d:.1}+{d:.1}) && (angsep({d:.4},{d:.4},RA_SCZ,DEC_SCZ)<{d:.0})" \
            \\  roicut=n \
            \\  evfile={s} \
            \\  outfile={s}
            , .{
                spacecraft_path,
                bex.rock,
                bex.ra,
                bex.dec,
                bex.roi,
                bex.zenith_limit,
                bex.ra,
                bex.dec,
                bex.sun_minimum,
                bex.roi,
                bex.ra,
                bex.dec,
                bex.bore,
                bex.eventfile_cut,
                bex.eventfile_gti,
            }),
    });

    // 5. Probability photometry steps (diffuse response & source probabilities)
    if (bex.use_probability) {
        if (bex.dodiffuse) {
            try commands.append(.{
                .name = "gtdiffrsp - Calculate diffuse response",
                .command = try fmt.allocPrint(allocator,
                    \\gtdiffrsp chatter=2 \
                    \\  evfile={s} scfile={s} \
                    \\  srcmdl={s} irfs={s}
                    , .{
                        bex.eventfile_gti,
                        spacecraft_path,
                        inputmodel_path,
                        bex.irfs,
                    }),
            });
        }

        try commands.append(.{
            .name = "gtsrcprob - Compute source probabilities",
            .command = try fmt.allocPrint(allocator,
                \\gtsrcprob chatter=2 \
                \\  evfile={s} outfile={s} \
                \\  scfile={s} srcmdl={s} irfs={s}
                , .{
                    bex.eventfile_gti,
                    bex.eventfile_prob,
                    spacecraft_path,
                    inputmodel_path,
                    bex.irfs,
                }),
        });
    }

    // 6. gtbin - Create light curve
    try commands.append(.{
        .name = "gtbin LC - Create light curve",
        .command = try fmt.allocPrint(allocator,
            \\gtbin chatter=2 algorithm=LC \
            \\  evfile={s} outfile={s} scfile={s} \
            \\  tbinalg=LIN tstart={d:.1} tstop={d:.1} dtime={d:.1}
            , .{
                bex.eventfile_gti,
                bex.lc_file,
                spacecraft_path,
                bex.tmin,
                bex.tmax,
                bex.bin_size,
            }),
    });

    // 7. gtexposure - Calculate exposure for light curve bins
    if (bex.use_probability) {
        try commands.append(.{
            .name = "gtexposure - Calculate exposure with model",
            .command = try fmt.allocPrint(allocator,
                \\gtexposure chatter=2 \
                \\  infile={s} scfile={s} \
                \\  irfs={s} srcmdl={s} target={s}
                , .{
                    bex.lc_file,
                    spacecraft_path,
                    bex.irfs,
                    inputmodel_path,
                    bex.target_name,
                }),
        });
    } else {
        try commands.append(.{
            .name = "gtexposure - Calculate exposure with spectral index",
            .command = try fmt.allocPrint(allocator,
                \\gtexposure chatter=2 \
                \\  infile={s} scfile={s} \
                \\  irfs={s} srcmdl=none specin={d:.2}
                , .{
                    bex.lc_file,
                    spacecraft_path,
                    bex.irfs,
                    bex.spectral_index,
                }),
        });
    }

    // 8. gtbary - Apply barycentric correction
    if (bex.barycenter) {
        try commands.append(.{
            .name = "gtbary - Apply barycenter correction",
            .command = try fmt.allocPrint(allocator,
                \\gtbary chatter=2 \
                \\  evfile={s} outfile={s} scfile={s} \
                \\  ra={d:.4} dec={d:.4} tcorrect=BARY
                , .{
                    bex.lc_file,
                    bex.lc_bary_file,
                    spacecraft_path,
                    bex.ra,
                    bex.dec,
                }),
        });
    }
}

test "bex appendCommands" {
    const allocator = std.testing.allocator;
    const config = benchmark.Config{};
    var commands = std.array_list.Managed(benchmark.CommandDef).init(allocator);
    defer {
        for (commands.items) |cmd| {
            allocator.free(cmd.command);
        }
        commands.deinit();
    }

    try appendCommands(allocator, &commands, config);
    try std.testing.expect(commands.items.len == 7);
}

test "bex custom config with annulus and diffuse" {
    const allocator = std.testing.allocator;
    const config = benchmark.Config{};
    var commands = std.array_list.Managed(benchmark.CommandDef).init(allocator);
    defer {
        for (commands.items) |cmd| {
            allocator.free(cmd.command);
        }
        commands.deinit();
    }

    const custom = BexConfig{
        .roi_inner = 0.5,
        .dodiffuse = true,
        .use_probability = true,
        .barycenter = true,
    };

    try appendBexCommands(allocator, &commands, config, custom);
    try std.testing.expect(commands.items.len == 9);
}
