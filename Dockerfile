# This dockerfile is meant to compile a core-lightning image with clboss
# It is using multi stage build:
# * downloader: Download litecoin/bitcoin and qemu binaries needed for core-lightning
# * builder: Compile core-lightning dependencies, then core-lightning itself with static linking
# * final: Copy the binaries required at runtime
# From the root of the repository, run "docker build -t yourimage:yourtag ."

# - downloader -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:trixie-slim as downloader

ARG TARGETPLATFORM

ENV DEBIAN_FRONTEND noninteractive

RUN --mount=type=cache,target=/var/cache/apt \
    rm -v /etc/apt/apt.conf.d/docker-clean && \
      printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/docker-keep-cache && \
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
      echo 'Etc/UTC' > /etc/timezone && \
      dpkg-reconfigure --frontend noninteractive tzdata && \
      apt-get update && \
      apt-get install -y locales && \
      sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
      echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
      dpkg-reconfigure -f noninteractive locales && \
      update-locale LANG=en_US.UTF-8 && \
      apt-get dist-upgrade -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN --mount=type=cache,target=/var/cache/apt \
    set -ex && apt-get install -y --no-install-recommends ca-certificates dirmngr wget

WORKDIR /opt

# install tini binary
ENV TINI_VERSION=v0.18.0
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   TINI_ARCH=amd64; TINI_SHA256SUM=eadb9d6e2dc960655481d78a92d2c8bc021861045987ccd3e27c7eae5af0cf33  ;; \
         "linux/arm64")   TINI_ARCH=arm64; TINI_SHA256SUM=ce3f642d73d58d7c8d745e65b5a9b5de7040fbfa1f7bee2f6207bb28207d8ca1  ;; \
         "linux/arm32v7") TINI_ARCH=armhf; TINI_SHA256SUM=efc2933bac3290aae1180a708f58035baf9f779833c2ea98fcce0ecdab68aa61  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1  ;; \
      esac; } \
    && wget --timeout=60 --waitretry=0 --tries=8 -O /tini \
         "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${TINI_ARCH}" \
    && echo "${TINI_SHA256SUM}  /tini" | sha256sum -c - \
    && chmod +x /tini

# install bitcoin binaries
ARG BITCOIN_VERSION=28.4
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz  ;; \
         "linux/arm64")   BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz  ;; \
         "linux/arm32v7") BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-arm-linux-gnueabihf.tar.gz  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1  ;; \
      esac; } \
    && BITCOIN_URL=https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${BITCOIN_TARBALL} \
    && BITCOIN_ASC_URL=https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/SHA256SUMS \
    && mkdir /opt/bitcoin && cd /opt/bitcoin \
    && wget --timeout=60 --waitretry=0 --tries=8 -O ${BITCOIN_TARBALL} "${BITCOIN_URL}" \
    && wget --timeout=60 --waitretry=0 --tries=8 -O SHA256SUMS "${BITCOIN_ASC_URL}" \
    && grep ${BITCOIN_TARBALL} SHA256SUMS | tee ${BITCOIN_TARBALL}.sha256sum \
    && sha256sum -c ${BITCOIN_TARBALL}.sha256sum \
    && BD=bitcoin-${BITCOIN_VERSION}/bin \
    && tar -xzvf ${BITCOIN_TARBALL} ${BD}/bitcoin-cli --strip-components=1 \
    && rm ${BITCOIN_TARBALL} SHA256SUMS ${BITCOIN_TARBALL}.sha256sum

# install litecoin binaries
ENV LITECOIN_VERSION=0.21.5.6
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-x86_64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=3c0a217651a431ef446641669a0b74ce7dbcd9b9ed1a118fc830b8f6779ee83f  ;; \
         "linux/arm64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-aarch64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=81c3ca2a7fcbccaabaf0a0ea2022f1990787f0cc1937aaad4dcc61d2856799a8  ;; \
         "linux/arm32v7") LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-arm-linux-gnueabihf.tar.gz; \
                          LITECOIN_SHA256=5b8925e4fd28accfe14d6137cf226dde651b320d65f36f4e9decbcefb2fcae7e  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1  ;; \
      esac; } \
    && LITECOIN_URL=https://download.litecoin.org/litecoin-${LITECOIN_VERSION}/linux/${LITECOIN_TARBALL} \
    && mkdir /opt/litecoin && cd /opt/litecoin \
    && wget --timeout=60 --waitretry=0 --tries=8 -O ${LITECOIN_TARBALL} "${LITECOIN_URL}" \
    && echo "${LITECOIN_SHA256}  ${LITECOIN_TARBALL}" | sha256sum -c - \
    && BD=litecoin-${LITECOIN_VERSION}/bin \
    && tar -xzvf ${LITECOIN_TARBALL} ${BD}/litecoin-cli --strip-components=1 --exclude=*-qt \
    && rm ${LITECOIN_TARBALL}


# - builder -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:trixie-slim as builder

ARG TARGETPLATFORM

ARG MAKE_NPROC=0 \
    LIGHTNINGD_VERSION=v26.06.7-binary

ENV DEBIAN_FRONTEND noninteractive

RUN --mount=type=cache,target=/var/cache/apt \
    rm -v /etc/apt/apt.conf.d/docker-clean && \
      printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/docker-keep-cache && \
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
      echo 'Etc/UTC' > /etc/timezone && \
      dpkg-reconfigure --frontend noninteractive tzdata && \
      apt-get update && \
      apt-get install -y locales && \
      sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
      echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
      dpkg-reconfigure -f noninteractive locales && \
      update-locale LANG=en_US.UTF-8 && \
      apt-get dist-upgrade -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ENV PYTHON_VERSION=3 \
    PYTHON_VERSION_FULL=3.13 \
    PIP_ROOT_USER_ACTION=ignore \
    PATH=${PATH}:/root/.local/bin

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bison \
        build-essential \
        ca-certificates \
        curl \
        dirmngr \
        flex \
        gettext \
        git \
        gnupg \
        jq \
        libc-dev\
        libev-dev \
        libevent-dev \
        libicu-dev \
        libffi-dev \
        libgmp-dev \
        libpq-dev \
        libsecp256k1-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libtool \
        lowdown \
        net-tools \
        pkg-config \
        protobuf-compiler \
        python${PYTHON_VERSION_FULL} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-full \
        python${PYTHON_VERSION}-mako \
        python${PYTHON_VERSION}-pip \
        python${PYTHON_VERSION}-setuptools \
        python${PYTHON_VERSION}-wheel \
        qemu-user-static \
        unzip \
        wget \
        tclsh \
        zlib1g \
        zlib1g-dev && \
        update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION_FULL} 1 && \
        { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || rm -v /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; } && \
        pip3 install --resume-retries 128 uv

# rust
ENV RUST_VERSION=1.98.0 \
    RUST_PROFILE=release \
    CARGO_OPTS=--profile=release \
    PATH=${PATH}:/root/.cargo/bin
RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
        sh -s -- -y --default-toolchain=${RUST_VERSION} --component=rustfmt

# su-exec
RUN mkdir /tmp/su-exec && cd /tmp/su-exec && \
      wget --timeout=60 --waitretry=0 --tries=8 -O su-exec.c "https://raw.githubusercontent.com/ncopa/su-exec/master/su-exec.c" && \
      mkdir -p /tmp/su-exec_install/usr/local/bin && \
      SUEXEC_BINARY="/tmp/su-exec_install/usr/local/bin/su-exec" && \
      gcc -Wall su-exec.c -o"${SUEXEC_BINARY}" && \
      chown root:root "${SUEXEC_BINARY}" && \
      chmod 0755 "${SUEXEC_BINARY}"

# Core Lightning
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    if ! echo "${LIGHTNINGD_VERSION}" | grep -q -E '.*-binary$'; then \
      { case ${TARGETPLATFORM} in \
          "linux/amd64")   COPTFLAGS="-O2 -march=x86-64";                                   TARGET_ARCH="x86_64-linux-gnu";    RUST_ARCH="x86_64-unknown-linux-gnu"; ;; \
          "linux/arm64")   COPTFLAGS="-O2 -march=armv8-a";                                  TARGET_ARCH="aarch64-linux-gnu";   RUST_ARCH="aarch64-unknown-linux-gnu"; ;; \
          "linux/arm32v7") COPTFLAGS="-O2 -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard"; TARGET_ARCH="arm-linux-gnueabihf"; RUST_ARCH="armv7-unknown-linux-gnueabihf"; ;; \
          *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1;  ;; \
        esac; \
      } && \
        export PKG_CONFIG_LIBDIR="/usr/lib/${TARGET_ARCH}/pkgconfig" PKG_CONFIG_PATH="/usr/lib/${TARGET_ARCH}/pkgconfig" && \
        STRIP_BINARY="${TARGET_ARCH}-strip" && \
        cd /tmp && \
        { while ! GIT_HTTP_LOW_SPEED_LIMIT=131072 GIT_HTTP_LOW_SPEED_TIME=10 git clone --recursive --depth 1 --branch ${LIGHTNINGD_VERSION} https://github.com/ElementsProject/lightning; do \
            rm -rf lightning; done; } && \
        cd /tmp/lightning && \
        mkdir ./.cargo && \
        printf '[build]\ntarget = "%s"\nrustflags = ["-C", "target-cpu=generic"]\n\n[target.%s]\nlinker = "%s-gcc"\n' "${RUST_ARCH}" "${RUST_ARCH}" "${TARGET_ARCH}" > ./.cargo/config.toml && \
        sed -e 's/^\t\$(INSTALL_DATA) \(\$([^)]\+)\).*$/ifneq (\1,)\n\0\nendif/' -i Makefile && \
        sed -e '/^PLUGINS += \$(RUST_PLUGINS)$/a\\nrust-plugins : $(RUST_PLUGINS)\n.PHONY : rust-plugins' -i plugins/Makefile && \
        set -x && \
        uv sync --all-extras --all-groups --frozen && \
        ./configure --prefix=/usr/local \
          --disable-address-sanitizer \
          --disable-compat \
          --disable-fuzzing \
          --disable-ub-sanitize \
          --disable-valgrind \
          --enable-rust \
          --enable-static && \
        uv run make \
         COVERAGE="" ALL_TEST_PROGRAMS="" ALL_FUZZ_TARGETS="" DEVTOOLS="" COPTFLAGS="${COPTFLAGS}" RUST_PROFILE="release" TARGET="${RUST_ARCH}" CARGO_OPTS="--release --target=${RUST_ARCH}" CLN_RPC_EXAMPLES="" CLN_GRPC_EXAMPLES="" CLN_PLUGIN_EXAMPLES="" CLNREST_EXAMPLES="" \
         -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) && \
        uv run make \
         COVERAGE="" ALL_TEST_PROGRAMS="" ALL_FUZZ_TARGETS="" DEVTOOLS="" COPTFLAGS="${COPTFLAGS}" RUST_PROFILE="release" TARGET="${RUST_ARCH}" CARGO_OPTS="--release --target=${RUST_ARCH}" CLN_RPC_EXAMPLES="" CLN_GRPC_EXAMPLES="" CLN_PLUGIN_EXAMPLES="" CLNREST_EXAMPLES="" \
         -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) cln-rpc-all cln-grpc-all && \
        COPTFLAGS="${COPTFLAGS}" cargo build --release --target="${RUST_ARCH}" && \
        make \
         COVERAGE="" ALL_TEST_PROGRAMS="" ALL_FUZZ_TARGETS="" DEVTOOLS="" COPTFLAGS="${COPTFLAGS}" RUST_PROFILE="release" TARGET="${RUST_ARCH}" CARGO_OPTS="--release --target=${RUST_ARCH}" CLN_RPC_EXAMPLES="" CLN_GRPC_EXAMPLES="" CLN_PLUGIN_EXAMPLES="" CLNREST_EXAMPLES="" \
         -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) rust-plugins && \
        uv run make \
         COVERAGE="" ALL_TEST_PROGRAMS="" ALL_FUZZ_TARGETS="" DEVTOOLS="" COPTFLAGS="${COPTFLAGS}" RUST_PROFILE="release" TARGET="${RUST_ARCH}" CARGO_OPTS="--release --target=${RUST_ARCH}" CLN_RPC_EXAMPLES="" CLN_GRPC_EXAMPLES="" CLN_PLUGIN_EXAMPLES="" CLNREST_EXAMPLES="" \
         DESTDIR=/tmp/lightning_install install && \
        find /tmp/lightning_install/ -type f -executable -exec file {} + | awk -F: '/ELF/ { print $1 }' | xargs -n 1 -r -t ${STRIP_BINARY} --strip-unneeded; \
   else \
      CLN_TARBALL="clightning-${LIGHTNINGD_VERSION%-binary}" && \
      INTEGRITY_FILE="SHA256SUMS-${LIGHTNINGD_VERSION%-binary}" && \
      { case ${TARGETPLATFORM} in \
          "linux/amd64")   CLN_TARBALL="${CLN_TARBALL}-Ubuntu-24.04-amd64.tar.xz"; ;; \
          "linux/arm64")   CLN_TARBALL="${CLN_TARBALL}-Ubuntu-24.04-arm64.tar.xz"; INTEGRITY_FILE="${INTEGRITY_FILE}-arm64"; ;; \
          *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1;  ;; \
        esac; \
      } && \
      { for key in \
          4E4A142F8BD3C38A56B362ED578CAC08472545C5 \
          B731AAC521B013859313F674A26D6D9FE088ED58 \
          653B19F33DF7EFF3E9D1C94CC3F21EE387FF4CD2 \
          8A079421A871D0B1083511937AB4802ED5A639F3 \
         ; do \
             gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key" || \
             gpg --batch --keyserver hkps://api.protonmail.ch --recv-keys "$key" || \
             gpg --batch --keyserver keys.openpgp.org --recv-keys "$key" || \
             gpg --batch --keyserver keyserver.pgp.com --recv-keys "$key" || \
             gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key" || \
             gpg --batch --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys "$key" ; \
        done; } && \
      CLN_TARBALL_URL="https://github.com/ElementsProject/lightning/releases/download/${LIGHTNINGD_VERSION%-binary}/${CLN_TARBALL}" && \
      INTEGRITY_FILE_URL="https://github.com/ElementsProject/lightning/releases/download/${LIGHTNINGD_VERSION%-binary}/${INTEGRITY_FILE}" && \
      mkdir -p /tmp/lightning && \
      cd /tmp/lightning && \
      wget --timeout=60 --waitretry=0 --tries=8 -O "${CLN_TARBALL}" "${CLN_TARBALL_URL}" && \
      wget --timeout=60 --waitretry=0 --tries=8 -O "${INTEGRITY_FILE}" "${INTEGRITY_FILE_URL}" && \
      wget --timeout=60 --waitretry=0 --tries=8 -O "${INTEGRITY_FILE}.asc" "${INTEGRITY_FILE_URL}.asc" && \
      gpg --verify "${INTEGRITY_FILE}.asc" "${INTEGRITY_FILE}" && \
      sha256sum -c  "${INTEGRITY_FILE}" --ignore-missing && \
      mkdir -p /tmp/lightning_install/usr/local && \
      tar -C /tmp/lightning_install/usr/local --strip-components=2 -xvf "${CLN_TARBALL}"; \
   fi;

# CLBOSS
COPY ./clboss-patches/ /tmp/clboss-patches/
ARG CLBOSS_GIT_HASH=4f6c460b51014faf3926bec693d147e06ab7f1a3 \
      XREBALANCE_VERSION=v0.4.6
RUN --mount=type=cache,target=/var/cache/apt \
    --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    { case ${TARGETPLATFORM} in \
        "linux/amd64")   COPTFLAGS="-O2 -march=x86-64";                                   TARGET_ARCH="x86_64-linux-gnu";    RUST_ARCH="x86_64-unknown-linux-gnu"; ;; \
        "linux/arm64")   COPTFLAGS="-O2 -march=armv8-a";                                  TARGET_ARCH="aarch64-linux-gnu";   RUST_ARCH="aarch64-unknown-linux-gnu"; ;; \
        "linux/arm32v7") COPTFLAGS="-O2 -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=hard"; TARGET_ARCH="arm-linux-gnueabihf"; RUST_ARCH="armv7-unknown-linux-gnueabihf"; ;; \
        *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1;  ;; \
      esac; \
    } && \
   AR="${TARGET_ARCH}-ar" && AS="${TARGET_ARCH}-as" && CC="${TARGET_ARCH}-gcc" && CXX="${TARGET_ARCH}-g++" && LD="${TARGET_ARCH}-ld" && STRIP="${TARGET_ARCH}-strip" && \
   apt-get install -y --no-install-recommends \
        autoconf-archive \
        dnsutils \
        libcurl4-gnutls-dev \
        libev-dev \
        libsqlite3-dev \
        libunwind-dev && \
      cd /tmp && \
      mkdir clboss && cd clboss && \
      git init && git remote add origin https://github.com/tsjk/clboss && \
      git fetch --depth 1 origin ${CLBOSS_GIT_HASH} && \
      git checkout FETCH_HEAD && \
      { [ $(ls -1 /tmp/clboss-patches/*.patch 2> /dev/null | wc -l) -le 0 ] || \
          ( for f in /tmp/clboss-patches/*.patch; do echo && echo "${f}:" && patch -p1 < ${f} || exit 1; done ); } && \
      echo && \
      ( set -x && \
          autoreconf -f -i && \
          ./configure --prefix=/usr/local && \
          make -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) && \
          make DESTDIR=/tmp/clboss_install install ) && \
      cd /tmp && \
      { while ! GIT_HTTP_LOW_SPEED_LIMIT=131072 GIT_HTTP_LOW_SPEED_TIME=10 git clone --depth 1 --branch ${XREBALANCE_VERSION} https://github.com/ksedgwic/xrebalance.git; do \
          rm -rf xrebalance; done; } && \
      cd xrebalance && \
      mkdir ./.cargo && \
      printf '[build]\ntarget = "%s"\nrustflags = ["-C", "target-cpu=generic"]\n\n[target.%s]\nlinker = "%s-gcc"\n' "${RUST_ARCH}" "${RUST_ARCH}" "${TARGET_ARCH}" > ./.cargo/config.toml && \
      ( set -x && \
          cargo build --release --target="${RUST_ARCH}" && \
          install -o root -g root -m 0755 -p -v "./target/${RUST_ARCH}/release/xrebalance" /tmp/clboss_install/usr/local/bin/ )


# - node builder -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} node:26-trixie-slim as node-builder

ARG TARGETPLATFORM

ARG RTL_VERSION=0.15.11

ENV DEBIAN_FRONTEND noninteractive

RUN --mount=type=cache,target=/var/cache/apt \
    rm -v /etc/apt/apt.conf.d/docker-clean && \
      printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/docker-keep-cache && \
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
      echo 'Etc/UTC' > /etc/timezone && \
      dpkg-reconfigure --frontend noninteractive tzdata && \
      apt-get update && \
      apt-get install -y locales && \
      sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
      echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
      dpkg-reconfigure -f noninteractive locales && \
      update-locale LANG=en_US.UTF-8 && \
      apt-get dist-upgrade -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN --mount=type=cache,target=/var/cache/apt \
    set -ex && apt-get install -y --no-install-recommends ca-certificates patch patchutils wget

# RTL
RUN mkdir -p /tmp/RTL_install/usr/local && \
    cd /tmp/RTL_install/usr/local && \
    wget --timeout=60 --waitretry=0 --tries=8 \
      -O ./RTL-v${RTL_VERSION}.tar.gz \
      "https://github.com/Ride-The-Lightning/RTL/archive/refs/tags/v${RTL_VERSION}.tar.gz" && \
    tar xf RTL-v${RTL_VERSION}.tar.gz && \
    rm RTL-v${RTL_VERSION}.tar.gz && \
    mv RTL-${RTL_VERSION} RTL && \
    cd RTL && \
    npm install --legacy-peer-deps --omit=dev && \
    npm prune --production --legacy-peer-deps


# - final -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} node:26-trixie-slim as final

ARG TARGETPLATFORM

ARG LIGHTNINGD_VERSION=v26.06.7-binary \
    LIGHTNINGD_UID=1001
ENV LIGHTNINGD_HOME=/home/lightning
ENV LIGHTNINGD_DATA=${LIGHTNINGD_HOME}/.lightning \
    LIGHTNINGD_NETWORK=bitcoin \
    LIGHTNINGD_RPC_PORT=9835 \
    LIGHTNINGD_PORT=9735 \
    CLNREST_PORT=3010 \
    RTL_PORT=3000 \
    TOR_SOCKSD="" \
    TOR_CTRLD="" \
    NETWORK_RPCD=""

RUN --mount=type=cache,target=/var/cache/apt \
    rm -v /etc/apt/apt.conf.d/docker-clean && \
      printf 'Binary::apt::APT::Keep-Downloaded-Packages "true";\n' > /etc/apt/apt.conf.d/docker-keep-cache && \
      echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
      echo 'Etc/UTC' > /etc/timezone && \
      dpkg-reconfigure --frontend noninteractive tzdata && \
      apt-get update && \
      apt-get install -y locales && \
      sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
      echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
      dpkg-reconfigure -f noninteractive locales && \
      update-locale LANG=en_US.UTF-8 && \
      apt-get dist-upgrade -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

COPY --from=builder /tmp/su-exec_install/ /
COPY --from=builder /tmp/lightning_install/ /
COPY --from=builder /tmp/clboss_install/ /
COPY --from=node-builder /tmp/RTL_install/ /

ENV PYTHON_VERSION=3 \
    PYTHON_VERSION_FULL=3.13 \
    PIP_ROOT_USER_ACTION=ignore

RUN --mount=type=cache,target=/var/cache/apt \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        inotify-tools \
        libpq5 \
        libsecp256k1-2 \
        libsodium23 \
        libsqlite3-0 \
        jq \
        lowdown \
        net-tools \
        openssl \
        python${PYTHON_VERSION_FULL} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-full \
        python${PYTHON_VERSION}-mako \
        python${PYTHON_VERSION}-pip \
        python${PYTHON_VERSION}-setuptools \
        python${PYTHON_VERSION}-wheel \
        qemu-user-static \
        socat \
        tor \
        torsocks \
        wget \
        zlib1g && \
    apt-get install -y --no-install-recommends    `# 'CLBOSS dependencies'` \
        binutils \
        dnsutils \
        libev4 \
        libcurl3t64-gnutls \
        libsqlite3-0 \
        libunwind-dev && \
    apt-get auto-clean && \
    rm -rf /var/lib/apt/lists/* && \
    { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || rm -v /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; } && \
    update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION_FULL} 1 && \
    pip3 install --resume-retries 128 uv && \
    userdel -r node > /dev/null 2>&1 && \
    useradd --no-log-init --user-group \
      --create-home --home-dir ${LIGHTNINGD_HOME} \
      --shell /bin/bash --uid ${LIGHTNINGD_UID} lightning && \
    mkdir -p "${LIGHTNINGD_HOME}/.config/lightning" && \
    touch "${LIGHTNINGD_HOME}/.config/lightning/lightningd.conf" && \
    mkdir -p "${LIGHTNINGD_HOME}/.config/RTL" && \
    mkdir -p "${LIGHTNINGD_HOME}/.config/RTL/channel-backup" && \
    mkdir -p "${LIGHTNINGD_HOME}/.config/RTL/logs" && \
    ( cd /usr/local/RTL && \
        ln -s "${LIGHTNINGD_HOME}/.config/RTL/RTL-Config.json" && \
        ln -s "${LIGHTNINGD_HOME}/.config/RTL/channels-backup" && \
        ln -s "${LIGHTNINGD_HOME}/.config/RTL/logs" ) && \
    chown -R -h lightning:lightning "${LIGHTNINGD_HOME}" && \
    mkdir "${LIGHTNINGD_DATA}" && \
    chown -R -h lightning:lightning "${LIGHTNINGD_DATA}" && \
    rm -rf /tmp/* && \
    { if find /usr/local/ -type f -executable -exec ldd {} + 2>&1 | grep -q -E ' => not found$'; then \
        find /usr/local/ -type f -executable -exec ldd {} + 2>&1; exit 1; \
      fi; };

COPY ./entrypoint.sh /entrypoint.sh
COPY ./gossip-store-watcher.sh /usr/local/bin/gossip-store-watcher.sh
COPY ./RTL-Config.json ${LIGHTNINGD_HOME}/.config/RTL/RTL-Config.json
RUN chmod 0755 /entrypoint.sh && \
      chmod 0755 /usr/local/bin/gossip-store-watcher.sh && \
      chown -R -h lightning:lightning "${LIGHTNINGD_HOME}"

COPY --from=downloader /opt/bitcoin/bin /usr/bin
COPY --from=downloader /opt/litecoin/bin /usr/bin
COPY --from=downloader "/tini" /usr/bin/tini

WORKDIR "${LIGHTNINGD_HOME}"

VOLUME "${LIGHTNINGD_HOME}/.config/lightning"
VOLUME "${LIGHTNINGD_DATA}"
EXPOSE ${LIGHTNINGD_PORT} ${LIGHTNINGD_RPC_PORT} ${C_LIGHTNING_REST_PORT} ${C_LIGHTNING_REST_DOCPORT} ${RTL_PORT}

ENTRYPOINT  [ "/usr/bin/tini", "--", "/entrypoint.sh" ]
CMD ["lightningd"]
