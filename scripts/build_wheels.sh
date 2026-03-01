#!/bin/bash
# Build pyslang wheels for multiple Python versions inside the CentOS 7 Docker container.
# INSIDE-CONTAINER script. Key features:
#   - timeout on ALL network/long operations to avoid hanging indefinitely
#   - statically link libstdc++/libgcc so wheel only depends on glibc 2.17
#   - auditwheel repair to produce manylinux_2_17 tagged wheel
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(dirname "$SCRIPT_DIR")/slang"
OUTPUT_DIR="$(dirname "$SCRIPT_DIR")/dist"
PYTHON_VERSIONS=("3.8" "3.9" "3.10" "3.11")
CONDA=/opt/python38/bin/conda

# Timeouts (seconds)
TIMEOUT_DOWNLOAD=120     # curl
TIMEOUT_CONDA=600        # conda create env
TIMEOUT_PIP=300          # pip install deps
TIMEOUT_BUILD=2400       # cmake compile (~40 min max per version)
TIMEOUT_REPAIR=120       # auditwheel repair

PYSLANG_VERSION="${1:-}"

mkdir -p "$OUTPUT_DIR"

export CC=/opt/gcc-14/bin/gcc
export CXX=/opt/gcc-14/bin/g++
export PATH="/opt/gcc-14/bin:/opt/cmake-3.27.7-linux-x86_64/bin:$PATH"
export LD_LIBRARY_PATH="/opt/gcc-14/lib64:${LD_LIBRARY_PATH:-}"

echo "========================================"
echo " Building pyslang wheels"
echo " Python versions: ${PYTHON_VERSIONS[*]}"
echo " Version: ${PYSLANG_VERSION:-<unchanged>}"
echo "========================================"

# ── patchelf (needed by auditwheel) ──────────────────────────────────────────
# Pre-installed in centos7-gcc14-multi_py image; fallback for other envs.
if ! command -v patchelf &>/dev/null; then
    echo ">>> [$(date +%H:%M:%S)] Installing patchelf (timeout ${TIMEOUT_DOWNLOAD}s)..."
    timeout $TIMEOUT_DOWNLOAD curl -fSL \
        -o /tmp/patchelf.tar.gz \
        "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz" \
        || { echo "ERROR: patchelf download timed out"; exit 1; }
    cd /tmp && tar xzf patchelf.tar.gz && cp bin/patchelf /usr/local/bin/
    echo "   $(patchelf --version)"
fi

# ── Configure conda proxy (conda needs explicit config, not just env vars) ───
if [ -n "${https_proxy:-}" ]; then
    echo ">>> Configuring conda proxy: ${https_proxy}"
    $CONDA config --set proxy_servers.http  "${https_proxy}" 2>/dev/null || true
    $CONDA config --set proxy_servers.https "${https_proxy}" 2>/dev/null || true
fi

# ── Create conda envs + install build deps ───────────────────────────────────
# In centos7-gcc14-multi_py image these envs already exist; loop is a no-op.
# Fallback: creates envs on-the-fly when using base image instead.
for PYVER in "${PYTHON_VERSIONS[@]}"; do
    ENV_DIR="/opt/pyenvs/py${PYVER//./}"
    PIP="$ENV_DIR/bin/pip"

    if [ ! -d "$ENV_DIR" ]; then
        echo ">>> [$(date +%H:%M:%S)] conda create Python $PYVER (timeout ${TIMEOUT_CONDA}s)..."
        timeout $TIMEOUT_CONDA $CONDA create -y -p "$ENV_DIR" python="$PYVER" \
            --channel conda-forge --channel defaults \
            || { echo "ERROR: conda create timed out for Python $PYVER"; exit 1; }
        echo ">>> [$(date +%H:%M:%S)] pip install build deps Python $PYVER (timeout ${TIMEOUT_PIP}s)..."
        timeout $TIMEOUT_PIP $PIP install --upgrade pip setuptools wheel \
            --timeout 30 --retries 2 -q \
            || { echo "ERROR: pip upgrade timed out for Python $PYVER"; exit 1; }
        timeout $TIMEOUT_PIP $PIP install \
            "pybind11>=2.10,<4" scikit-build-core pybind11-stubgen auditwheel \
            --timeout 30 --retries 2 -q \
            || { echo "ERROR: pip install build deps timed out for Python $PYVER"; exit 1; }
        echo "   done."
    else
        echo ">>> [PRE-BAKED] Python $PYVER env already exists, skipping setup."
    fi
done

# ── Patch version ─────────────────────────────────────────────────────────────
if [ -n "$PYSLANG_VERSION" ]; then
    echo ">>> Patching pyproject.toml version to $PYSLANG_VERSION..."
    sed -i "s/^version = .*/version = \"$PYSLANG_VERSION\"/" "$SRC_DIR/pyproject.toml"
fi

# ── Build + repair wheels ─────────────────────────────────────────────────────
for PYVER in "${PYTHON_VERSIONS[@]}"; do
    ENV_DIR="/opt/pyenvs/py${PYVER//./}"
    PYTHON="$ENV_DIR/bin/python"
    # Prepend env to PATH for this version (don't keep accumulating)
    export PATH="$ENV_DIR/bin:/opt/gcc-14/bin:/opt/cmake-3.27.7-linux-x86_64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    echo ""
    echo "========================================"
    echo " [$(date +%H:%M:%S)] Building Python $PYVER"
    echo "========================================"

    BUILD_DIR="/tmp/build_py${PYVER//./}"
    rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
    cd "$SRC_DIR"

    echo ">>> Compiling (timeout ${TIMEOUT_BUILD}s, ~10-20 min expected)..."
    # Static-link libstdc++ and libgcc so the .so only depends on glibc
    timeout $TIMEOUT_BUILD $PYTHON -m pip wheel . \
        --no-build-isolation \
        --no-cache-dir \
        --wheel-dir "$BUILD_DIR" \
        "--config-settings=cmake.define.CMAKE_CXX_FLAGS=-static-libstdc++ -static-libgcc" \
        "--config-settings=cmake.define.CMAKE_SHARED_LINKER_FLAGS=-static-libstdc++ -static-libgcc" \
        "--config-settings=cmake.define.CMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc" \
        2>&1 \
        || { echo "ERROR: Build timed out or failed for Python $PYVER"; exit 1; }

    WHEEL_FILE=$(ls "$BUILD_DIR"/*.whl 2>/dev/null | head -1)
    [ -z "$WHEEL_FILE" ] && { echo "ERROR: No wheel produced for Python $PYVER"; exit 1; }
    echo ">>> Built: $(basename "$WHEEL_FILE")"

    # Show GLIBC symbols required — helps diagnose auditwheel failures
    echo ">>> Checking GLIBC symbol requirements..."
    TMPUNPACK="/tmp/unpack_${PYVER//./}"
    rm -rf "$TMPUNPACK" && mkdir -p "$TMPUNPACK"
    $PYTHON -c "import zipfile; zipfile.ZipFile('$WHEEL_FILE').extractall('$TMPUNPACK')"
    SO_FILE=$(find "$TMPUNPACK" -name "*.so" | head -1)
    if [ -n "$SO_FILE" ]; then
        objdump -T "$SO_FILE" 2>/dev/null \
            | grep -oP 'GLIBC_[0-9.]+' | sort -uV \
            | awk '{printf "   %s\n", $0}' || true
    fi
    rm -rf "$TMPUNPACK"

    echo ">>> [$(date +%H:%M:%S)] auditwheel repair (timeout ${TIMEOUT_REPAIR}s)..."
    timeout $TIMEOUT_REPAIR $ENV_DIR/bin/auditwheel repair "$WHEEL_FILE" \
        --plat manylinux_2_17_x86_64 \
        --wheel-dir "$OUTPUT_DIR" \
        || { echo "ERROR: auditwheel repair failed for Python $PYVER"; exit 1; }

    REPAIRED=$(ls "$OUTPUT_DIR"/*cp${PYVER//./}*.whl 2>/dev/null | tail -1)
    echo ">>> DONE: $(basename "${REPAIRED:-MISSING}")"
done

echo ""
echo "========================================"
echo " ALL WHEELS BUILT SUCCESSFULLY"
echo "========================================"
ls -lh "$OUTPUT_DIR"/*.whl
