#!/bin/bash
set -euo pipefail

CONFIGURATION="Release"
NATIVE_OPT=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
SHARED_DIR="$BUILD_DIR/scripts"
# Default project root: two directories above this script, which matches a
# build/<os>/build.sh embedded in a project. Override with -p/--project (or
# the PROJECT_ROOT env var) to build any other Rust project; every path
# this script needs is resolved relative to itself.
PROJECT_ROOT="${PROJECT_ROOT:-$(dirname "$(dirname "$SCRIPT_DIR")")}"

# The cargo targets to build are auto-detected from the project (see
# detect_bin_names) and can be overridden with --bin NAME (repeatable) or the
# BIN_NAME environment variable; --all builds every binary target the project
# defines, in one cargo invocation. The output binaries in bin/ are named after
# those targets.
ALL_BINS=false
BIN_NAMES=()
[[ -n "${BIN_NAME:-}" ]] && BIN_NAMES+=("$BIN_NAME")

source "$SHARED_DIR/utils.sh"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "    -c, --configuration CONF    Debug or Release [default: Release]"
    echo "    -b, --bin NAME              Binary target to build, repeatable [default: auto-detected]"
    echo "    -a, --all                   Build every binary target in the project"
    echo "    -p, --project DIR           Project root to build [default: two dirs above script]"
    echo "    -n, --native                Enable -C target-cpu=native"
    echo "    -h, --help                  Show this help"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--configuration)
            CONFIGURATION="$2"
            if [[ ! "$CONFIGURATION" =~ ^(Debug|Release)$ ]]; then
                echo -e "${RED}Error: Invalid configuration '$CONFIGURATION'. Must be Debug or Release.${NC}" >&2
                exit 1
            fi
            shift 2 ;;
        -b|--bin)
            BIN_NAMES+=("$2")
            shift 2 ;;
        -a|--all) ALL_BINS=true; shift 1 ;;
        -p|--project)
            PROJECT_ROOT="$2"
            shift 2 ;;
        -n|--native) NATIVE_OPT=true; shift 1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}Error: Unknown option '$1'${NC}" >&2; usage >&2; exit 1 ;;
    esac
done

# Normalize the project root and make sure it is actually a Cargo project.
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd || echo "$PROJECT_ROOT")"
if [[ ! -f "$PROJECT_ROOT/Cargo.toml" ]]; then
    echo -e "${RED}Error: no Cargo.toml found in project '$PROJECT_ROOT'${NC}" >&2
    echo -e "${YELLOW}Pass the project root with: $0 -p /path/to/project${NC}" >&2
    exit 1
fi

write_section "Open Grok Builder - Linux"
echo -e "Configuration: ${GREEN}$CONFIGURATION${NC}"

# --- System deps (Linux) ---
write_step "Checking system dependencies"

install_if_missing() {
    local cmd="$1" pkg="$2"
    if ! command -v "$cmd" &>/dev/null; then
        if command -v apt-get &>/dev/null; then
            sudo apt-get update -qq && sudo apt-get install -y "$pkg"
        elif command -v pacman &>/dev/null; then
            sudo pacman -S --noconfirm --needed "$pkg"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y "$pkg"
        else
            echo -e "${YELLOW}WARNING: $cmd not found. Install $pkg manually.${NC}"
        fi
    fi
}

install_if_missing cmake cmake
install_if_missing pkg-config pkg-config
install_if_missing pkgconf pkgconf

write_end_step

# --- Rust ---
write_step "Checking Rust"

# ensure_rust_toolchain() lives in scripts/utils.sh and is shared with
# scripts/setup_rust.sh, the full provisioning path (version check, install or
# update, cross targets, artifacts report).
if ! ensure_rust_toolchain; then
    write_end_step
    exit 1
fi

echo -e "${GREEN}rustc: $(rustc --version)${NC}"
echo -e "${GREEN}cargo: $(cargo --version)${NC}"

write_end_step

# --- Resolve binary targets (auto-detected, overridable) ---
# Every binary target the project defines, one name per line, in cargo's order
# and without duplicates. The metadata JSON is parsed with awk, so the builder
# needs neither jq nor python3: every target object cargo emits is flat
# (scalars and string arrays, no nested objects), so each object whose kind
# array carries "bin" can be matched directly and its name read out.
detect_bin_names() {
    local json
    json="$(cargo metadata --manifest-path "$PROJECT_ROOT/Cargo.toml" --no-deps --format-version 1 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        echo -e "${RED}Error: could not read Cargo metadata - is this a Cargo project?${NC}" >&2
        echo -e "${YELLOW}Specify the binary explicitly with: $0 --bin NAME (or BIN_NAME=NAME)${NC}" >&2
        return 1
    fi

    printf '%s' "$json" | awk '
        {
            rest = $0
            while (match(rest, /\{[^{}]*"kind":\[[^]]*"bin"[^]]*\][^{}]*\}/)) {
                obj = substr(rest, RSTART, RLENGTH)
                if (match(obj, /"name":"[^"]*"/)) {
                    print substr(obj, RSTART + 8, RLENGTH - 9)
                }
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    ' | awk '!seen[$0]++'
}

# Every binary target with --all, the ones named with --bin (or BIN_NAME),
# otherwise the project's first binary target. An empty list is an error, never
# a silent no-op.
TARGETS=()
if [[ "$ALL_BINS" == "true" ]]; then
    while IFS= read -r name; do
        [[ -n "$name" ]] && TARGETS+=("$name")
    done < <(detect_bin_names)
elif [[ ${#BIN_NAMES[@]} -gt 0 ]]; then
    TARGETS=("${BIN_NAMES[@]}")
else
    while IFS= read -r name; do
        TARGETS+=("$name")
        break
    done < <(detect_bin_names)
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo -e "${RED}Error: no binary target in $PROJECT_ROOT (library-only project?).${NC}" >&2
    echo -e "${YELLOW}Specify the binary explicitly with: $0 --bin NAME (or BIN_NAME=NAME), or build every one with --all${NC}" >&2
    exit 1
fi

# --- Build ---
write_step "Building ${TARGETS[*]}"

cd "$PROJECT_ROOT"

if [[ "$NATIVE_OPT" == "true" ]]; then
    export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=native"
    echo -e "${GRAY}Native optimizations enabled${NC}"
fi

# Force ort-sys to select the CUDA 13 onnxruntime dist instead of auto-
# detecting to cu12. ort-sys consults ORT_CUDA_VERSION (its CUDA_VERSION
# build var) first; 13 -> cu13. ORT_CUDA_VERSION is allowed to stay empty
# to let ort auto-detect on machines with another CUDA major.
if [[ -n "${ORT_CUDA_VERSION:-}" ]]; then
    echo -e "${GRAY}ORT_CUDA_VERSION=${ORT_CUDA_VERSION} (forcing ort-sys CUDA dist)${NC}"
fi

# One cargo call for every target: the shared dependencies are compiled once,
# and each --bin adds one binary rather than one build.
BIN_ARGS=()
for name in "${TARGETS[@]}"; do
    BIN_ARGS+=(--bin "$name")
done

if [[ "$CONFIGURATION" == "Release" ]]; then
    cargo build --release "${BIN_ARGS[@]}"
    OUT_DIR="$PROJECT_ROOT/target/release"
else
    cargo build "${BIN_ARGS[@]}"
    OUT_DIR="$PROJECT_ROOT/target/debug"
fi

write_end_step

# --- Copy to bin/ ---
mkdir -p "$PROJECT_ROOT/bin"
for name in "${TARGETS[@]}"; do
    cp "$OUT_DIR/$name" "$PROJECT_ROOT/bin/$name"
    echo -e "${GREEN}Binary -> $PROJECT_ROOT/bin/$name${NC}"
done

# --- Copy CUDA provider dylibs next to the binary ---
# ort-sys places libonnxruntime_providers_{cuda,shared}.so in the cargo
# target dir (as symlinks to the cached cu13 dist); the rm -rf target/
# below would strip them, and without them the ort CUDA execution provider
# cannot load at runtime. Resolve and copy them into bin/ so a GPU build
# is self-contained. A CPU-only build has nothing to copy (loop no-ops).
PROV_DIR="$OUT_DIR"
for prov in libonnxruntime_providers_cuda.so libonnxruntime_providers_shared.so; do
    if [[ -e "$PROV_DIR/$prov" || -L "$PROV_DIR/$prov" ]]; then
        cp -L "$PROV_DIR/$prov" "$PROJECT_ROOT/bin/$prov"
        echo -e "${GREEN}Provider -> $PROJECT_ROOT/bin/$prov${NC}"
    fi
done

# --- Remove target/ ---
write_step "Removing target/ (~100GB freed)"
rm -rf "$PROJECT_ROOT/target"
echo -e "${GREEN}Done${NC}"
