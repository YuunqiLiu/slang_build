#!/bin/bash
# Test pyslang wheels by installing and running basic import + test for each Python version.
# This script is designed to run INSIDE the Docker container.
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
    ENV_NAME="py${PYVER//./}"
    ENV_DIR="/opt/pyenvs/$ENV_NAME"
    PYTHON="$ENV_DIR/bin/python"
    PIP="$ENV_DIR/bin/pip"

    echo ""
    echo "--- Testing Python $PYVER ---"

    # Find matching wheel
    WHEEL_FILE=$(ls "$DIST_DIR"/pyslang-*-cp${PYVER//./}-*.whl 2>/dev/null | head -1)
    if [ -z "$WHEEL_FILE" ]; then
        echo "ERROR: No wheel found for Python $PYVER"
        FAILED=1
        continue
    fi
    echo "Wheel: $(basename "$WHEEL_FILE")"

    # Install wheel
    $PIP install --force-reinstall "$WHEEL_FILE" 2>&1 | tail -3
    $PIP install pytest 2>&1 | tail -1

    # Basic import test
    echo ">>> Import test..."
    $PYTHON -c "
import pyslang
print(f'  pyslang imported successfully')
print(f'  SVInt(-3) = {pyslang.SVInt(-3)}')
t = pyslang.SyntaxTree.fromText('module m; endmodule')
print(f'  SyntaxTree created, root kind: {t.root.kind}')
print(f'  PASS: Basic import test')
" || { echo "FAIL: Import test for Python $PYVER"; FAILED=1; continue; }

    # Run actual tests
    echo ">>> Running pytest..."
    cd "$SRC_DIR"
    $PYTHON -m pytest pyslang/tests/ -x -q 2>&1 | tail -10
    TEST_EXIT=${PIPESTATUS[0]}
    if [ "$TEST_EXIT" -ne 0 ]; then
        echo "FAIL: pytest for Python $PYVER"
        FAILED=1
    else
        echo "PASS: All tests for Python $PYVER"
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
