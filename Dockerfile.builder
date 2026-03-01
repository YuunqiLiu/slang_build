FROM ghcr.io/yuunqiliu/centos7-gcc14-multi_py:latest

# ── slang-builder 派生镜像（已简化） ─────────────────────────────────────────
# centos7-gcc14-multi_py:latest 已内置：
#   - Python 3.8 / 3.9 / 3.10 / 3.11 conda envs  (/opt/pyenvs/pyXY)
#   - pybind11 scikit-build-core pybind11-stubgen auditwheel（每个 env）
#   - patchelf 0.18.0 (/usr/local/bin/patchelf)
# 本文件仅作验证 + 保留 LABEL 用于标识。

SHELL ["/bin/bash", "-c"]

# Verify inherited environment
RUN for PYVER in 3.8 3.9 3.10 3.11; do \
        ENV_DIR="/opt/pyenvs/py${PYVER//./}"; \
        echo -n "Python ${PYVER}: "; \
        "$ENV_DIR/bin/python" --version; \
        "$ENV_DIR/bin/python" -c "import scikit_build_core, pybind11, auditwheel; print('  build tools OK')"; \
    done && \
    echo "patchelf: $(patchelf --version)"

LABEL org.opencontainers.image.description="pyslang wheel builder: CentOS7 + GCC14 + Python 3.8-3.11 + patchelf + auditwheel"
