#!/usr/bin/env bash
# Build whisper.cpp with the Vulkan backend into ~/.local/bin/whisper-cli,
# reusing the GGML models that voxtype already downloaded.
#
# Why: the whisper-cpp package in the distro repos is CPU-only, which is slow
# for long videos. This builds a GPU (Vulkan) whisper-cli that the plugin's
# 'auto' transcription mode picks up automatically. Each transcription runs as
# its own process, so the model is loaded into VRAM on start and freed when the
# process exits (no idle VRAM usage).
#
# No root required. Only needs `git` and (if missing) `mise` for cmake/ninja,
# plus the Vulkan loader + glslc which are usually already installed.
set -euo pipefail

SRC="${SRC:-$HOME/.local/src}"
PREFIX="${PREFIX:-$HOME/.local}"
MODELS="$HOME/.local/share/voxtype/models"
BUILD_DIR="$SRC/whisper.cpp/build"

mkdir -p "$SRC" "$PREFIX/bin"

need() { command -v "$1" >/dev/null 2>&1; }

# --- build tooling: cmake + ninja ------------------------------------------
if ! need cmake || ! need ninja; then
  if need mise; then
    echo "[setup] installing cmake + ninja via mise"
    mise install cmake ninja >/dev/null
    mise use -g cmake ninja >/dev/null
    export PATH="$HOME/.local/share/mise/shims:$PATH"
  else
    echo "ERROR: cmake and ninja are required." >&2
    echo "       Install them (e.g. 'sudo pacman -S cmake ninja') or install mise." >&2
    exit 1
  fi
fi
need glslc || { echo "ERROR: glslc (shaderc) is required for the Vulkan shaders." >&2; exit 1; }

VULKAN_LIB="$(find /usr/lib /usr/lib64 -maxdepth 1 -name 'libvulkan.so' 2>/dev/null | head -n1)"
[ -n "$VULKAN_LIB" ] || { echo "ERROR: libvulkan.so not found (install vulkan-icd-loader)." >&2; exit 1; }

# --- sources ---------------------------------------------------------------
for repo in Vulkan-Headers SPIRV-Headers whisper.cpp; do
  url=""
  case "$repo" in
    Vulkan-Headers) url="https://github.com/KhronosGroup/Vulkan-Headers" ;;
    SPIRV-Headers)  url="https://github.com/KhronosGroup/SPIRV-Headers"  ;;
    whisper.cpp)    url="https://github.com/ggml-org/whisper.cpp"        ;;
  esac
  if [ ! -d "$SRC/$repo/.git" ]; then
    echo "[setup] cloning $repo"
    git clone --depth 1 "$url" "$SRC/$repo"
  fi
done

# --- SPIRV-Headers (header-only cmake config used by ggml-vulkan) ----------
echo "[setup] installing SPIRV-Headers"
cmake -S "$SRC/SPIRV-Headers" -B "$SRC/SPIRV-Headers/build" -G Ninja \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --install "$SRC/SPIRV-Headers/build" >/dev/null

# --- whisper.cpp: static binary + Vulkan backend ---------------------------
echo "[setup] configuring whisper.cpp (Vulkan, static)"
rm -rf "$BUILD_DIR"
cmake -S "$SRC/whisper.cpp" -B "$BUILD_DIR" -G Ninja \
  -DGGML_VULKAN=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DVulkan_INCLUDE_DIR="$SRC/Vulkan-Headers/include" \
  -DVulkan_LIBRARY="$VULKAN_LIB" \
  -DCMAKE_PREFIX_PATH="$PREFIX" \
  -DCMAKE_CXX_FLAGS="-I$PREFIX/include" \
  -DCMAKE_C_FLAGS="-I$PREFIX/include"

echo "[setup] building (this takes a few minutes)"
cmake --build "$BUILD_DIR" --config Release -j "$(nproc)"

cp -f "$BUILD_DIR/bin/whisper-cli" "$PREFIX/bin/whisper-cli"
echo "[setup] installed $PREFIX/bin/whisper-cli"

# --- sanity check ----------------------------------------------------------
if [ -f "$MODELS/ggml-small.bin" ]; then
  echo "[setup] voxtype models detected in $MODELS:"
  ls -1 "$MODELS"/ggml-*.bin 2>/dev/null | sed 's/^/         /'
else
  echo "[setup] no voxtype GGML models found in $MODELS;"
  echo "         set a custom command in the plugin Settings or install voxtype models."
fi
echo "[setup] done. The plugin's 'auto' mode will use this GPU build."
