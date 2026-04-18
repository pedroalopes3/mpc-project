# Stage 1: The Build Lab
FROM ubuntu:22.04 AS builder

# Optimized build dependencies
RUN apt-get update && apt-get install -y \
    automake build-essential clang cmake git libboost-dev \
    libboost-thread-dev libgmp-dev libntl-dev libsodium-dev \
    libssl-dev libtool m4 pkg-config python3 python3-pip texinfo yasm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/mp-spdz
RUN git clone https://github.com/data61/MP-SPDZ.git .

# Configure for multi-protocol support
# USE_NTL=1 is required for many malicious protocols (like MASCOT/CowGear)
RUN echo "USE_NTL = 1" >> CONFIG.mine && \
    arch="$(dpkg --print-architecture)" && \
    if [ "$arch" = "amd64" ]; then \
        echo "ARCH = -march=x86-64" >> CONFIG.mine; \
    elif [ "$arch" = "arm64" ]; then \
        echo "ARCH = -march=armv8-a" >> CONFIG.mine; \
    else \
        echo "ARCH = -march=native" >> CONFIG.mine; \
    fi

# Compile the specific virtual machines for the course
# -j$(nproc) uses all available CPU cores to speed up the build
RUN make setup && \
    make -j$(nproc) \
    shamir-party.x \
    mascot-party.x \
    replicated-ring-party.x \
    semi-party.x

# Stage 2: The Student Runtime
FROM ubuntu:22.04

# Only install runtime libraries to keep the image slim
RUN apt-get update && apt-get install -y \
    python3 libgmp10 libgmpxx4ldbl libntl44 libsodium23 libssl3 \
    libboost-filesystem1.74.0 libboost-iostreams1.74.0 libboost-system1.74.0 libboost-thread1.74.0 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mp-spdz

# Copy only the compiled binaries and necessary scripts
COPY --from=builder /usr/src/mp-spdz/Compiler/ ./Compiler/
COPY --from=builder /usr/src/mp-spdz/Scripts/ ./Scripts/
COPY --from=builder /usr/src/mp-spdz/*.x ./
COPY --from=builder /usr/src/mp-spdz/libSPDZ.so* ./
COPY --from=builder /usr/src/mp-spdz/compile.py ./
COPY --from=builder /usr/src/mp-spdz/local/lib/ ./local/lib/

# Pre-create standard directories
RUN mkdir Player-Data Programs

# Ensure dynamic linker can find MP-SPDZ + locally-built deps (Boost built by `make setup`)
ENV LD_LIBRARY_PATH=/mp-spdz:/mp-spdz/local/lib

# Backfill helpers that vary across MP-SPDZ versions (e.g. `Compiler.util.prefix_sum`)
RUN python3 - <<'PY'
from pathlib import Path

p = Path('/mp-spdz/Compiler/util.py')
text = p.read_text()

if 'def prefix_sum' not in text:
    text += """

# Added by mpc-project to provide a stable helper across MP-SPDZ versions.
def prefix_sum(op, sequence):
    \"\"\"Inclusive prefix sums (scan) over *sequence* using binary function *op*.

    Supports Python lists/tuples and MP-SPDZ Arrays (e.g., `sint.Array`).
    \"\"\"
    if isinstance(sequence, (list, tuple)):
        if not sequence:
            return []
        acc = sequence[0]
        res = [acc]
        for x in sequence[1:]:
            acc = op(acc, x)
            res.append(acc)
        return res

    try:
        n = len(sequence)
        value_type = sequence.value_type
    except Exception:
        raise CompilerError('prefix_sum() expects a list/tuple or an MP-SPDZ Array-like object')

    res = value_type.Array(n)
    if n == 0:
        return res

    res[0] = sequence[0]

    from Compiler.library import for_range

    @for_range(1, n)
    def _(i):
        res[i] = op(res[i - 1], sequence[i])

    return res
"""

    p.write_text(text)
PY

# Metadata
LABEL description="MPC Course Environment - Multi-Protocol Support"
CMD ["/bin/bash"]
