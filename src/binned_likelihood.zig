const std = @import("std");
const benchmark = @import("fermitools_benchmark.zig");

const mem = std.mem;
const fmt = std.fmt;

/// Append the Fermi LAT binned likelihood tutorial commands.
pub fn appendCommands(
    allocator: mem.Allocator,
    commands: *std.array_list.Managed(benchmark.CommandDef),
    config: benchmark.Config,
) !void {
    // Get full paths for input files
    const spacecraft_path = try config.getDataPath(allocator, config.spacecraft_file);
    defer allocator.free(spacecraft_path);

    const inputmodel_path = try config.getDataPath(allocator, config.input_model);
    defer allocator.free(inputmodel_path);

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

    // 4. gtbin CMAP - Create 2D counts map
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

    // 6. gtltcube - Compute livetime cube
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

    // 7. gtexpcube2 - Compute all-sky exposure map
    try commands.append(.{
        .name = "gtexpcube2 - Compute exposure map",
        .command = try fmt.allocPrint(allocator,
            \\gtexpcube2 infile={s} cmap=none \
            \\  outfile={s} irfs={s} evtype={s} \
            \\  nxpix={} nypix={} binsz={d:.2} \
            \\  coordsys={s} xref={d:.4} yref={d:.4} \
            \\  axisrot=0 proj={s} \
            \\  emin={d:.0} emax={d:.0} enumbins={}
            , .{
                config.ltcube_file,
                config.expcube_file,
                config.irfs,
                config.exp_evttype,
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

    // 8. gtsrcmaps - Compute source maps
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
                inputmodel_path,
                config.expcube_file,
                config.srcmaps_file,
            }),
    });

    // 9. gtlike - Perform likelihood fit
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
                inputmodel_path,
                config.output_model,
            }),
    });
}