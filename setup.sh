#!/usr/bin/env bash
#
# PolyBench/C 4.2.1 - Automated Setup Script
#
# Usage:
#   ./setup.sh [options]
#
# This script automates the full setup of PolyBench/C:
#   1. Checks prerequisites (gcc, perl, make)
#   2. Generates config.mk with user-specified options
#   3. Generates per-benchmark Makefiles
#   4. Optionally builds all benchmarks
#   5. Optionally runs all benchmarks
#

set -euo pipefail

# ──────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────
CC="${CC:-gcc}"
OPT_LEVEL="-O2"
DATASET="LARGE"
DATA_TYPE=""
BUILD_ALL=0
RUN_ALL=0
CLEAN=0
VERBOSE=0
OUTPUT_DIR="."
EXTRA_CFLAGS=""

# PolyBench options (0=off, 1=on)
PB_TIME=0
PB_CYCLE_TIMER=0
PB_GFLOPS=0
PB_DUMP_ARRAYS=0
PB_USE_C99=0
PB_USE_RESTRICT=0
PB_STACK_ARRAYS=0
PB_SCALAR_LB=0
PB_NO_FLUSH_CACHE=0
PB_LINUX_FIFO=0
PB_PAPI=0
PB_PADDING=0
PB_INTER_PADDING=0
PB_CACHE_SIZE=""

# ──────────────────────────────────────────────
# Color helpers
# ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR]${NC}  $*" >&2; }
die()   { error "$@"; exit 1; }

# ──────────────────────────────────────────────
# Usage
# ──────────────────────────────────────────────
usage() {
    cat <<'USAGE'
PolyBench/C 4.2.1 - Setup Script

Usage: ./setup.sh [options]

General:
  -h, --help              Show this help message
  -v, --verbose           Enable verbose output
  --clean                 Clean all generated files and exit

Compiler:
  --cc <compiler>         C compiler          (default: gcc, env: $CC)
  --opt <level>           Optimization level   (default: -O2)
  --cflags <flags>        Additional CFLAGS    (default: none)

Dataset:
  --dataset <size>        Dataset size: MINI, SMALL, MEDIUM, LARGE, EXTRALARGE
                                               (default: LARGE)
  --data-type <type>      Data type: int, float, double
                                               (default: per-benchmark)

PolyBench Options:
  --time                  Enable execution time reporting (POLYBENCH_TIME)
  --cycle-timer           Use cycle-accurate TSC timer
  --gflops                Report GFLOPS
  --dump-arrays           Dump live-out arrays to stderr
  --c99                   Use C99 array prototypes
  --restrict              Use restrict qualifier
  --stack-arrays          Allocate arrays on stack (instead of heap)
  --scalar-lb             Use scalar loop bounds
  --no-flush-cache        Disable cache flushing before timing
  --fifo-scheduler        Use Linux FIFO real-time scheduler (needs root)
  --papi                  Enable PAPI hardware counters (needs libpapi)
  --padding <N>           Array padding factor (default: 0)
  --inter-padding <N>     Inter-array padding factor (default: 0)
  --cache-size <KB>       Cache size in KB for flushing (default: 33MB)

Actions:
  --build                 Build all benchmarks after setup
  --run                   Build and run all benchmarks after setup
  --output-dir <dir>      Output directory for generated files (default: .)

Examples:
  # Basic setup with default settings
  ./setup.sh

  # Setup with timing, build all
  ./setup.sh --time --build

  # Setup for small dataset, dump arrays, build and run
  ./setup.sh --dataset SMALL --dump-arrays --run

  # Use clang with aggressive optimization
  ./setup.sh --cc clang --opt "-O3 -march=native" --time --build

  # Setup for verification (reference output)
  ./setup.sh --opt -O0 --dump-arrays --dataset SMALL --build
USAGE
}

# ──────────────────────────────────────────────
# Parse arguments
# ──────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        -v|--verbose)     VERBOSE=1; shift ;;
        --clean)          CLEAN=1; shift ;;
        --cc)             CC="$2"; shift 2 ;;
        --opt)            OPT_LEVEL="$2"; shift 2 ;;
        --cflags)         EXTRA_CFLAGS="$2"; shift 2 ;;
        --dataset)        DATASET="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
        --data-type)      DATA_TYPE="$2"; shift 2 ;;
        --time)           PB_TIME=1; shift ;;
        --cycle-timer)    PB_CYCLE_TIMER=1; shift ;;
        --gflops)         PB_GFLOPS=1; shift ;;
        --dump-arrays)    PB_DUMP_ARRAYS=1; shift ;;
        --c99)            PB_USE_C99=1; shift ;;
        --restrict)       PB_USE_RESTRICT=1; shift ;;
        --stack-arrays)   PB_STACK_ARRAYS=1; shift ;;
        --scalar-lb)      PB_SCALAR_LB=1; shift ;;
        --no-flush-cache) PB_NO_FLUSH_CACHE=1; shift ;;
        --fifo-scheduler) PB_LINUX_FIFO=1; shift ;;
        --papi)           PB_PAPI=1; shift ;;
        --padding)        PB_PADDING="$2"; shift 2 ;;
        --inter-padding)  PB_INTER_PADDING="$2"; shift 2 ;;
        --cache-size)     PB_CACHE_SIZE="$2"; shift 2 ;;
        --build)          BUILD_ALL=1; shift ;;
        --run)            RUN_ALL=1; BUILD_ALL=1; shift ;;
        --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
        *)                die "Unknown option: $1 (use --help for usage)" ;;
    esac
done

# ──────────────────────────────────────────────
# Resolve directories
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

UTILITIES_DIR="$SCRIPT_DIR/utilities"

# ──────────────────────────────────────────────
# Clean mode
# ──────────────────────────────────────────────
if [[ $CLEAN -eq 1 ]]; then
    info "Cleaning all generated files..."
    if [[ -f "$UTILITIES_DIR/clean.pl" ]]; then
        perl "$UTILITIES_DIR/clean.pl" "$OUTPUT_DIR"
    fi
    # Also remove output directory if it was custom
    if [[ "$OUTPUT_DIR" != "." ]] && [[ -d "$OUTPUT_DIR/config.mk" ]]; then
        rm -f "$OUTPUT_DIR/config.mk"
    fi
    rm -f "$OUTPUT_DIR/config.mk"
    ok "Clean complete."
    exit 0
fi

# ──────────────────────────────────────────────
# Banner
# ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     PolyBench/C 4.2.1 Setup Script      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
echo ""

# ──────────────────────────────────────────────
# Step 1: Check prerequisites
# ──────────────────────────────────────────────
info "Checking prerequisites..."

MISSING=0

# Check compiler
if command -v "$CC" &>/dev/null; then
    CC_VERSION=$("$CC" --version 2>&1 | head -n1)
    ok "Compiler: $CC ($CC_VERSION)"
else
    error "Compiler not found: $CC"
    MISSING=1
fi

# Check perl
if command -v perl &>/dev/null; then
    PERL_VERSION=$(perl -v 2>&1 | grep -oP 'v[\d.]+' | head -n1)
    ok "Perl: $PERL_VERSION"
else
    error "Perl not found (required for Makefile generation)"
    MISSING=1
fi

# Check make
if command -v make &>/dev/null; then
    MAKE_VERSION=$(make --version 2>&1 | head -n1)
    ok "Make: $MAKE_VERSION"
else
    error "Make not found"
    MISSING=1
fi

# Check PAPI if requested
if [[ $PB_PAPI -eq 1 ]]; then
    if ! pkg-config --exists papi 2>/dev/null && ! ldconfig -p 2>/dev/null | grep -q libpapi; then
        warn "PAPI requested but libpapi not found. Build may fail."
    else
        ok "PAPI: available"
    fi
fi

if [[ $MISSING -eq 1 ]]; then
    die "Missing prerequisites. Please install them and try again."
fi

echo ""

# ──────────────────────────────────────────────
# Step 2: Validate dataset
# ──────────────────────────────────────────────
case "$DATASET" in
    MINI|SMALL|MEDIUM|LARGE|EXTRALARGE)
        ok "Dataset: ${DATASET}_DATASET"
        ;;
    *)
        die "Invalid dataset: $DATASET (must be MINI, SMALL, MEDIUM, LARGE, or EXTRALARGE)"
        ;;
esac

# ──────────────────────────────────────────────
# Step 3: Build CFLAGS
# ──────────────────────────────────────────────
CFLAGS="$OPT_LEVEL"

# Dataset
CFLAGS+=" -D${DATASET}_DATASET"

# Data type
case "$DATA_TYPE" in
    int)    CFLAGS+=" -DDATA_TYPE_IS_INT" ;;
    float)  CFLAGS+=" -DDATA_TYPE_IS_FLOAT" ;;
    double) CFLAGS+=" -DDATA_TYPE_IS_DOUBLE" ;;
    "")     ;; # Use per-benchmark defaults
    *)      die "Invalid data type: $DATA_TYPE (must be int, float, or double)" ;;
esac

# PolyBench options
if [[ $PB_TIME -eq 1 ]];           then CFLAGS+=" -DPOLYBENCH_TIME"; fi
if [[ $PB_CYCLE_TIMER -eq 1 ]];    then CFLAGS+=" -DPOLYBENCH_CYCLE_ACCURATE_TIMER"; fi
if [[ $PB_GFLOPS -eq 1 ]];         then CFLAGS+=" -DPOLYBENCH_GFLOPS"; fi
if [[ $PB_DUMP_ARRAYS -eq 1 ]];    then CFLAGS+=" -DPOLYBENCH_DUMP_ARRAYS"; fi
if [[ $PB_USE_C99 -eq 1 ]];        then CFLAGS+=" -DPOLYBENCH_USE_C99_PROTO"; fi
if [[ $PB_USE_RESTRICT -eq 1 ]];   then CFLAGS+=" -DPOLYBENCH_USE_RESTRICT"; fi
if [[ $PB_STACK_ARRAYS -eq 1 ]];   then CFLAGS+=" -DPOLYBENCH_STACK_ARRAYS"; fi
if [[ $PB_SCALAR_LB -eq 1 ]];      then CFLAGS+=" -DPOLYBENCH_USE_SCALAR_LB"; fi
if [[ $PB_NO_FLUSH_CACHE -eq 1 ]]; then CFLAGS+=" -DPOLYBENCH_NO_FLUSH_CACHE"; fi
if [[ $PB_LINUX_FIFO -eq 1 ]];     then CFLAGS+=" -DPOLYBENCH_LINUX_FIFO_SCHEDULER"; fi
if [[ $PB_PAPI -eq 1 ]];           then CFLAGS+=" -DPOLYBENCH_PAPI"; fi

if [[ $PB_PADDING -ne 0 ]];       then CFLAGS+=" -DPOLYBENCH_PADDING_FACTOR=$PB_PADDING"; fi
if [[ $PB_INTER_PADDING -ne 0 ]]; then CFLAGS+=" -DPOLYBENCH_INTER_ARRAY_PADDING_FACTOR=$PB_INTER_PADDING"; fi
if [[ -n "$PB_CACHE_SIZE" ]];      then CFLAGS+=" -DPOLYBENCH_CACHE_SIZE_KB=$PB_CACHE_SIZE"; fi

# Extra user CFLAGS
if [[ -n "$EXTRA_CFLAGS" ]]; then CFLAGS+=" $EXTRA_CFLAGS"; fi

# PAPI link flag
EXTRA_FLAGS=""
if [[ $PB_PAPI -eq 1 ]]; then EXTRA_FLAGS="-lpapi"; fi

# ──────────────────────────────────────────────
# Step 4: Generate config.mk
# ──────────────────────────────────────────────
info "Generating config.mk..."

CONFIG_FILE="$OUTPUT_DIR/config.mk"

cat > "$CONFIG_FILE" <<EOF
# PolyBench/C 4.2.1 - Auto-generated by setup.sh
# $(date '+%Y-%m-%d %H:%M:%S')

CC=$CC
CFLAGS=$CFLAGS
EOF

ok "Generated: $CONFIG_FILE"

if [[ $VERBOSE -eq 1 ]]; then
    echo ""
    echo -e "  ${BOLD}CC${NC}     = $CC"
    echo -e "  ${BOLD}CFLAGS${NC} = $CFLAGS"
    echo ""
fi

# ──────────────────────────────────────────────
# Step 5: Generate per-benchmark Makefiles
# ──────────────────────────────────────────────
info "Generating per-benchmark Makefiles..."

perl "$UTILITIES_DIR/makefile-gen.pl" "$OUTPUT_DIR"

# Count generated Makefiles
MAKEFILE_COUNT=0
CATEGORIES=(
    "datamining"
    "linear-algebra/blas"
    "linear-algebra/kernels"
    "linear-algebra/solvers"
    "medley"
    "stencils"
)

for cat_dir in "${CATEGORIES[@]}"; do
    target="$OUTPUT_DIR/$cat_dir"
    if [[ -d "$target" ]]; then
        for bench_dir in "$target"/*/; do
            [[ -f "$bench_dir/Makefile" ]] && MAKEFILE_COUNT=$((MAKEFILE_COUNT + 1))
        done
    fi
done

ok "Generated $MAKEFILE_COUNT benchmark Makefiles"

# ──────────────────────────────────────────────
# Step 6: Build (optional)
# ──────────────────────────────────────────────
if [[ $BUILD_ALL -eq 1 ]]; then
    echo ""
    info "Building all benchmarks..."

    BUILD_OK=0
    BUILD_FAIL=0
    FAILED_LIST=()

    for cat_dir in "${CATEGORIES[@]}"; do
        target="$OUTPUT_DIR/$cat_dir"
        [[ -d "$target" ]] || continue

        for bench_dir in "$target"/*/; do
            [[ -d "$bench_dir" ]] || continue
            bench_name=$(basename "$bench_dir")

            if [[ $VERBOSE -eq 1 ]]; then
                info "Building $cat_dir/$bench_name..."
            fi

            if make -C "$bench_dir" clean &>/dev/null && make -C "$bench_dir" 2>/dev/null; then
                BUILD_OK=$((BUILD_OK + 1))
                if [[ $VERBOSE -eq 1 ]]; then ok "  $bench_name"; fi
            else
                BUILD_FAIL=$((BUILD_FAIL + 1))
                FAILED_LIST+=("$cat_dir/$bench_name")
                warn "  FAILED: $cat_dir/$bench_name"
            fi
        done
    done

    echo ""
    ok "Build complete: ${GREEN}$BUILD_OK passed${NC}, ${RED}$BUILD_FAIL failed${NC}"

    if [[ $BUILD_FAIL -gt 0 ]]; then
        warn "Failed benchmarks:"
        for f in "${FAILED_LIST[@]}"; do
            echo "    - $f"
        done
    fi
fi

# ──────────────────────────────────────────────
# Step 7: Run (optional)
# ──────────────────────────────────────────────
if [[ $RUN_ALL -eq 1 ]]; then
    echo ""
    info "Running all benchmarks..."

    RUN_OK=0
    RUN_FAIL=0

    for cat_dir in "${CATEGORIES[@]}"; do
        target="$OUTPUT_DIR/$cat_dir"
        [[ -d "$target" ]] || continue

        for bench_dir in "$target"/*/; do
            [[ -d "$bench_dir" ]] || continue
            bench_name=$(basename "$bench_dir")
            binary="$bench_dir/$bench_name"

            if [[ -x "$binary" ]]; then
                info "Running $cat_dir/$bench_name..."

                if "$binary" 2>/dev/null; then
                    RUN_OK=$((RUN_OK + 1))
                    ok "  $bench_name done"
                else
                    RUN_FAIL=$((RUN_FAIL + 1))
                    warn "  FAILED: $cat_dir/$bench_name"
                fi
            else
                warn "  SKIP: $bench_name (binary not found)"
            fi
        done
    done

    echo ""
    ok "Run complete: ${GREEN}$RUN_OK passed${NC}, ${RED}$RUN_FAIL failed${NC}"
fi

# ──────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Setup Complete ──────────────────────────${NC}"
echo ""
echo "  Compiler:   $CC"
echo "  CFLAGS:     $CFLAGS"
echo "  Benchmarks: $MAKEFILE_COUNT"
echo ""
echo "Next steps:"
echo "  # Build a single benchmark"
echo "  make -C linear-algebra/kernels/atax"
echo ""
echo "  # Build all benchmarks"
echo "  ./setup.sh --build"
echo ""
echo "  # Run a single benchmark"
echo "  ./linear-algebra/kernels/atax/atax"
echo ""
echo "  # Clean everything"
echo "  ./setup.sh --clean"
echo ""
