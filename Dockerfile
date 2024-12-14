# This dockerfile is meant to compile a core-lightning image with clboss
# It is using multi stage build:
# * downloader: Download litecoin/bitcoin and qemu binaries needed for core-lightning
# * builder: Compile core-lightning dependencies, then core-lightning itself with static linking
# * final: Copy the binaries required at runtime
# From the root of the repository, run "docker build -t yourimage:yourtag ."

# - downloader -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:bookworm-slim as downloader

ARG TARGETPLATFORM

ENV DEBIAN_FRONTEND noninteractive

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update -qq && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    apt-get dist-upgrade -qq -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN set -ex && apt-get install -qq --no-install-recommends ca-certificates dirmngr wget

WORKDIR /opt

# install tini binary
ENV TINI_VERSION=v0.18.0
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   TINI_ARCH=amd64; TINI_SHA256SUM=eadb9d6e2dc960655481d78a92d2c8bc021861045987ccd3e27c7eae5af0cf33  ;; \
         "linux/arm64")   TINI_ARCH=arm64; TINI_SHA256SUM=ce3f642d73d58d7c8d745e65b5a9b5de7040fbfa1f7bee2f6207bb28207d8ca1  ;; \
         "linux/arm32v7") TINI_ARCH=armhf; TINI_SHA256SUM=efc2933bac3290aae1180a708f58035baf9f779833c2ea98fcce0ecdab68aa61  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1  ;; \
      esac; } \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O /tini \
         "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${TINI_ARCH}" \
    && echo "${TINI_SHA256SUM}  /tini" | sha256sum -c - \
    && chmod +x /tini

# install bitcoin binaries
ARG BITCOIN_VERSION=25.2
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz  ;; \
         "linux/arm64")   BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz  ;; \
         "linux/arm32v7") BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-arm-linux-gnueabihf.tar.gz  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1  ;; \
      esac; } \
    && BITCOIN_URL=https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/${BITCOIN_TARBALL} \
    && BITCOIN_ASC_URL=https://bitcoincore.org/bin/bitcoin-core-${BITCOIN_VERSION}/SHA256SUMS \
    && mkdir /opt/bitcoin && cd /opt/bitcoin \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O ${BITCOIN_TARBALL} "${BITCOIN_URL}" \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O SHA256SUMS "${BITCOIN_ASC_URL}" \
    && grep ${BITCOIN_TARBALL} SHA256SUMS | tee ${BITCOIN_TARBALL}.sha256sum \
    && sha256sum -c ${BITCOIN_TARBALL}.sha256sum \
    && BD=bitcoin-${BITCOIN_VERSION}/bin \
    && tar -xzvf ${BITCOIN_TARBALL} ${BD}/bitcoin-cli --strip-components=1 \
    && rm ${BITCOIN_TARBALL} SHA256SUMS ${BITCOIN_TARBALL}.sha256sum

# install litecoin binaries
ENV LITECOIN_VERSION=0.21.3
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-x86_64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=ea231c630e2a243cb01affd4c2b95a2be71560f80b64b9f4bceaa13d736aa7cb  ;; \
         "linux/arm64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-aarch64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=e889ab7aaa514e1be7266ab335f82a7db1f5598ad514099a486023fe401808c7  ;; \
         "linux/arm32v7") LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-arm-linux-gnueabihf.tar.gz; \
                          LITECOIN_SHA256=4ce97f1723cfa46a06f890309a0405ef9046a8c057d071506adf7937b8c77f43  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM}."; exit 1  ;; \
      esac; } \
    && LITECOIN_URL=https://download.litecoin.org/litecoin-${LITECOIN_VERSION}/linux/${LITECOIN_TARBALL} \
    && mkdir /opt/litecoin && cd /opt/litecoin \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O ${LITECOIN_TARBALL} "${LITECOIN_URL}" \
    && echo "${LITECOIN_SHA256}  ${LITECOIN_TARBALL}" | sha256sum -c - \
    && BD=litecoin-${LITECOIN_VERSION}/bin \
    && tar -xzvf ${LITECOIN_TARBALL} ${BD}/litecoin-cli --strip-components=1 --exclude=*-qt \
    && rm ${LITECOIN_TARBALL}


# - builder -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:bookworm-slim as builder

ARG MAKE_NPROC=0 \
    LIGHTNINGD_VERSION=v24.02.2 \
    CLBOSS_GIT_HASH=5aa184eb01704ace56eb40c175e7867526340f31

ENV DEBIAN_FRONTEND noninteractive

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update -qq && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    apt-get dist-upgrade -qq -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

ENV PYTHON_VERSION=3 \
    PYTHON_VERSION_FULL=3.11
ENV PYTHONPATH=/usr/lib/python${PYTHON_VERSION_FULL}/site-packages \
    PIP_ROOT_USER_ACTION=ignore

RUN apt-get install -qq -y --no-install-recommends \
        autoconf \
        automake \
        build-essential \
        ca-certificates \
        curl \
        dirmngr \
        gettext \
        git \
        gnupg \
        libc-dev\
        libev-dev \
        libevent-dev \
        libffi-dev \
        libgmp-dev \
        libpq-dev \
        libsqlite3-dev \
        libssl-dev \
        libtool \
        pkg-config \
        protobuf-compiler \
        python${PYTHON_VERSION_FULL} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-mako \
        python${PYTHON_VERSION}-pip \
        python${PYTHON_VERSION}-setuptools \
        python${PYTHON_VERSION}-venv \
        python${PYTHON_VERSION}-wheel \
        qemu-user-static \
        wget\
        zlib1g \
        zlib1g-dev

RUN mkdir /tmp/su-exec && cd /tmp/su-exec && \
    wget -q --timeout=60 --waitretry=0 --tries=8 -O su-exec.c "https://raw.githubusercontent.com/ncopa/su-exec/master/su-exec.c" && \
    mkdir -p /tmp/su-exec_install/usr/local/bin && \
    SUEXEC_BINARY="/tmp/su-exec_install/usr/local/bin/su-exec" && \
    gcc -Wall su-exec.c -o"${SUEXEC_BINARY}" && \
    chown root:root "${SUEXEC_BINARY}" && \
    chmod 0755 "${SUEXEC_BINARY}"

ENV RUST_PROFILE=release \
    CARGO_OPTS=--profile=release \
    PATH=$PATH:/root/.cargo/bin
RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain=1.79 --component=rustfmt

RUN update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION_FULL} 1 && \
    curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors -sSL https://install.python-poetry.org | POETRY_VERSION=1.7.1 python${PYTHON_VERSION} - && \
    { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || rm /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; }

RUN export PATH="/root/.local/bin:$PATH" && \
    cd /tmp && \
    git clone --recursive --depth 1 --branch ${LIGHTNINGD_VERSION} https://github.com/ElementsProject/lightning && \
    cd /tmp/lightning && \
    wget -q --timeout=60 --waitretry=0 --tries=8 -O pr-7330.patch "https://patch-diff.githubusercontent.com/raw/ElementsProject/lightning/pull/7330.patch" && \
    wget -q --timeout=60 --waitretry=0 --tries=8 -O pr-7368.patch "https://patch-diff.githubusercontent.com/raw/ElementsProject/lightning/pull/7368.patch" && \
    patch -p1 < pr-7330.patch && rm -f pr-7330.patch && \
    patch -p1 < pr-7368.patch && rm -f pr-7368.patch && \
    sed -i '/^#include "config.h"$/a #include <bitcoin/short_channel_id.h>' gossipd/gossmap_manage.c && \
    sed -i -E 's/(fmt_short_channel_id\(\S+,\s*)([^& ])/\1\&\2/; s/(\s)fmt_short_channel_id\(/\1short_channel_id_to_str\(/g' common/gossmap.c gossipd/gossmap_manage.c && \
    pip3 wheel cryptography && \
    pip3 install --prefix=/usr grpcio-tools && \
    poetry env use system && \
    poetry lock --no-update && \
    poetry install && \
    ./configure --prefix=/usr/local \
      --disable-address-sanitizer \
      --disable-compat \
      --disable-fuzzing \
      --disable-ub-sanitize \
      --disable-valgrind \
      --enable-rust \
      --enable-static && \
    make -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) && \
    poetry run make DESTDIR=/tmp/lightning_install install && \
    poetry export -o ./requirements.txt --without-hashes --with dev

# CLBOSS
COPY ./clboss-patches/ /tmp/clboss-patches/
RUN [ $(ls -1 /tmp/clboss-patches/*.patch | wc -l) -gt 0 ] && \
    apt-get install -qq -y --no-install-recommends \
        libev-dev \
        libcurl4-gnutls-dev \
        libsqlite3-dev \
        dnsutils \
        autoconf-archive && \
    cd /tmp && \
    mkdir clboss && cd clboss && \
    git init && git remote add origin https://github.com/ZmnSCPxj/clboss && \
    git fetch --depth 1 origin ${CLBOSS_GIT_HASH} && \
    git checkout FETCH_HEAD && \
    ( for f in /tmp/clboss-patches/*.patch; do echo && echo "${f}:" && patch -p1 < ${f} || exit 1; done ) && \
    echo && autoreconf -f -i && \
    ./configure --prefix=/usr/local && \
    make -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) && \
    make DESTDIR=/tmp/clboss_install install


# - node builder -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} node:20-bookworm-slim as node-builder

ARG RTL_VERSION=0.15.4

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update -qq && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    apt-get dist-upgrade -qq -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN set -ex && apt-get install -qq --no-install-recommends ca-certificates patch patchutils wget

# RTL
RUN mkdir -p /tmp/RTL_install/usr/local && \
    cd /tmp/RTL_install/usr/local && \
    wget -q --timeout=60 --waitretry=0 --tries=8 \
      -O ./RTL-v${RTL_VERSION}.tar.gz \
      "https://github.com/Ride-The-Lightning/RTL/archive/refs/tags/v${RTL_VERSION}.tar.gz" && \
    tar xf RTL-v${RTL_VERSION}.tar.gz && \
    rm RTL-v${RTL_VERSION}.tar.gz && \
    mv RTL-${RTL_VERSION} RTL && \
    cd RTL && \
    npm install --legacy-peer-deps --omit=dev && \
    npm prune --production --legacy-peer-deps


# - final -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} node:20-bookworm-slim as final

ARG LIGHTNINGD_VERSION=v24.02.2 \
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

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update -qq && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8 && \
    apt-get dist-upgrade -qq -y --no-install-recommends

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

COPY ./entrypoint.sh /entrypoint.sh
COPY ./gossip-store-watcher.sh /usr/local/bin/gossip-store-watcher.sh
COPY --from=builder /tmp/lightning/ /tmp/lightning/
COPY --from=node-builder /tmp/RTL_install/ /

ENV PYTHON_VERSION=3 \
    PYTHON_VERSION_FULL=3.11
ENV PYTHONPATH=/usr/lib/python${PYTHON_VERSION_FULL}/site-packages \
    PIP_ROOT_USER_ACTION=ignore

RUN apt-get install -qq -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        inotify-tools \
        libpq5 \
        jq \
        openssl \
        python${PYTHON_VERSION_FULL} \
        python${PYTHON_VERSION}-pip \
        python${PYTHON_VERSION}-setuptools \
        python${PYTHON_VERSION}-wheel \
        qemu-user-static \
        socat \
        tor \
        torsocks \
        wget \
        zlib1g && \
    apt-get install -qq -y --no-install-recommends    `# 'CLBOSS dependencies'` \
        dnsutils \
        libev-dev \
        libcurl4-gnutls-dev \
        libsqlite3-dev && \
    apt-get auto-clean && \
    rm -rf /var/lib/apt/lists/* && \
    update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION_FULL} 1 && \
    { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || \
        rm /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; } && \
    pip3 install --prefix=/usr grpcio-tools && \
    pip3 install --prefix=/usr -r /tmp/lightning/requirements.txt && rm -rf /tmp/lightning && \
    pip3 cache purge && \
    chmod 0755 /entrypoint.sh && \
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
    rm -rf /tmp/*

COPY ./RTL-Config.json ${LIGHTNINGD_HOME}/.config/RTL/RTL-Config.json
RUN chown -R -h lightning:lightning "${LIGHTNINGD_HOME}"

COPY --from=builder /tmp/su-exec_install/ /
COPY --from=builder /tmp/lightning_install/ /
COPY --from=builder /tmp/clboss_install/ /
COPY --from=downloader /opt/bitcoin/bin /usr/bin
COPY --from=downloader /opt/litecoin/bin /usr/bin
COPY --from=downloader "/tini" /usr/bin/tini

WORKDIR "${LIGHTNINGD_HOME}"

VOLUME "${LIGHTNINGD_HOME}/.config/lightning"
VOLUME "${LIGHTNINGD_DATA}"
EXPOSE ${LIGHTNINGD_PORT} ${LIGHTNINGD_RPC_PORT} ${C_LIGHTNING_REST_PORT} ${C_LIGHTNING_REST_DOCPORT} ${RTL_PORT}

ENTRYPOINT  [ "/usr/bin/tini", "--", "/entrypoint.sh" ]
CMD ["lightningd"]
