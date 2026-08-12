# ftbenchmark
Scripts to benchmark the Fermitools on different systems.  

## Build Requirements
Zig=0.17

## Building the software
Clone the repository and run `zig build` in the top level directory.  The `fermi_benchmark` executable will be generated in the `zig-out/bin` directory.

## Installing Release Binaries
Download and unpack the tagged release tarball appropriate for your system architecture.  Currently x86_64 Linux builds and aarch64 MacOS builds are generated.  The unpacked tarball will contain a `bin` directory with the static-linked executable as well as a `data` directory containing input files for benchmarking.

## Running the software

`fermi_benchmark -d <path to data directory> -o <name of output file`

### Options
- -d - Path to the top level input data directory
- -o - Name of output file containing benchmarking statistics
- --dry-run - Run the benchmarks without executing the commands
