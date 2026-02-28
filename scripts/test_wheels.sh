#!/bin/bash
# Test pyslang wheels. Runs AFTER build_wheels.sh in the same container session,
# so /opt/pyenvs/pyXY conda envs are available.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$(dirname "$SCRIPT_DIR")/dist"
SRC_DIR="$(dirname "$SCRIPT_DIR")/slang"
PYTHON_VERSIONS=("3.8" "3.9" "3.10" "3.11")

echo "========================================"
echo " Testing pyslang wheels"
echo "========================================"

FAILED=0

for PYVER in "${PYTHON_VERSIONS[@]}"; do
    CPTAG="cp${PYVER//./}"
    ENV_DIR="/opt/pyenvs/py${PYVER//./}"

    echo ""
    echo "--- Testing Python $PYVER ---"

    # Find matching wheel
    WHEEL_FILE=$(ls "$DIST_DIR"/pyslang-*-${CPTAG}-*.whl 2>/dev/null | head -1)
    if [ -z "$WHEEL_FILE" ]; then
        echo "ERROR: No wheel found for Python $PYVER"
        FAILED=1
        continue
    fi
    echo "Wheel: $(basename "$WHEEL_FILE")"

    # Resolve Python binary: prefer conda env, fall back to system python
    if [ -x "$ENV_DIR/bin/python" ]; then
        PYBIN="$ENV_DIR/bin/python"
    elif command -v "python$PYVER" &>/dev/null; then
        PYBIN=$(command -v "python$PYVER")
    else
        echo "SKIP: no Python $PYVER found"
        continue
    fi

    # Create a fresh venv so install is isolated
    VENV="/tmp/test_venv_${CPTAG}"
    rm -rf "$VENV"
    "$PYBIN" -m venv "$VENV"
    "$VENV/bin/pip" install -q --force-reinstall "$WHEEL_FILE" || {
        echo "FAIL: pip install for Python $PYVER"; FAILED=1; continue
    }
    "$VENV/bin/pip" install -q pytest

    # Basic import test
    echo ">>> Import test..."
    "$VENV/bin/python" -c "
import pyslang
print(f'  SVInt(-3) = {pyslang.SVInt(-3)}')
t = pyslang.SyntaxTree.fromText('module m; endmodule')
print(f'  SyntaxTree root kind: {t.root.kind}')
print(f'  PASS: basic import')
" || { echo "FAIL: import test for Python $PYVER"; FAILED=1; continue; }

    # Run pytest suite (use if/else so pipefail doesn't abort the script on failure)
    # Python 3.8: upstream tests use 3.9+ syntax (functools.cache, list[str], etc.)
    # Collect incompatible files and ignore them
    PYTEST_EXTRA_ARGS=""
    if [ "$PYVER" = "3.8" ]; then
        IGNORE_FILES=""
        for tf in "$SRC_DIR"/pyslang/tests/test_*.py; do
            if "$VENV/bin/python" -c "import ast; ast.parse(open('$tf').read())" 2>/dev/null; then
                : # file parses OK
            else
                echo "  (skipping $(basename "$tf") — syntax incompatible with Python $PYVER)"
                IGNORE_FILES="$IGNORE_FILES --ignore=$tf"
            fi
        done
        PYTEST_EXTRA_ARGS="$IGNORE_FILES"
    fi
    echo ">>> Running pytest..."
    if "$VENV/bin/python" -m pytest "$SRC_DIR/pyslang/tests/" -x -q $PYTEST_EXTRA_ARGS 2>&1 | tail -10; then
        echo "PASS: Python $PYVER"
    else
        echo "FAIL: pytest for Python $PYVER"
        FAILED=1
    fi
done

echo ""
echo "========================================"
if [ "$FAILED" -ne 0 ]; then
    echo " SOME TESTS FAILED!"
    exit 1
else
    echo " ALL TESTS PASSED!"
fi
done

echo ""
echo "========================================"
if [ "$FAILED" -ne 0 ]; then
    echo " SOME TESTS FAILED!"
    exit 1
else
    echo " ALL TESTS PASSED!"
    exit 0
fi
