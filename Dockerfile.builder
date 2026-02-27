FROM ghcr.io/yuunqiliu/centos7-gcc14:latest

# ── patchelf ──────────────────────────────────────────────────────────────────
RUN curl -fSL \
    "https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz" \
    -o /tmp/patchelf.tar.gz \
    && cd /tmp && tar xzf patchelf.tar.gz \
    && cp bin/patchelf /usr/local/bin/ \
    && rm -rf /tmp/patchelf* \
    && patchelf --version

# ── conda proxy config ────────────────────────────────────────────────────────
# (proxy is only needed at build time, not baked in)

# ── Python environments: 3.8 / 3.9 / 3.10 / 3.11 ─────────────────────────────
ENV CONDA=/opt/python38/bin/conda \
    PATH="/opt/gcc-14/bin:/opt/cmake-3.27.7-linux-x86_64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RUN for PYVER in 3.8 3.9 3.10 3.11; do \
        ENV_DIR="/opt/pyenvs/py${PYVER//./}"; \
        echo "==> Creating conda env Python $PYVER ..."; \
        $CONDA create -y -p "$ENV_DIR" python="$PYVER" \
            --channel conda-forge --channel defaults; \
        echo "==> Installing build deps Python $PYVER ..."; \
        "$ENV_DIR/bin/pip" install --upgrade pip setuptools wheel -q; \
        "$ENV_DIR/bin/pip" install \
            "pybind11>=2.10,<4" scikit-build-core pybind11-stubgen auditwheel \
            --timeout 30 --retries 3 -q; \
        echo "==> Done Python $PYVER"; \
    done

# Verify
RUN for PYVER in 3.8 3.9 3.10 3.11; do \
        ENV_DIR="/opt/pyenvs/py${PYVER//./}"; \
        echo -n "Python $PYVER: "; \
        "$ENV_DIR/bin/python" --version; \
        "$ENV_DIR/bin/python" -c "import scikit_build_core, pybind11, auditwheel; print('  build tools OK')"; \
    done

LABEL org.opencontainers.image.description="pyslang wheel builder: CentOS7 + GCC14 + Python 3.8-3.11 + patchelf + auditwheel"
