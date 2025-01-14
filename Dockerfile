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
ARG BITCOIN_VERSION=26.2
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
ENV LITECOIN_VERSION=0.21.4
RUN { case ${TARGETPLATFORM} in \
         "linux/amd64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-x86_64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=857fc41091f2bae65c3bf0fd4d388fca915fc93a03f16dd2578ac3cc92898390  ;; \
         "linux/arm64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-aarch64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=517e3a9069e658eb92de98c934c61836589ee2410d99464a768a5698985926c9  ;; \
         "linux/arm32v7") LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-arm-linux-gnueabihf.tar.gz; \
                          LITECOIN_SHA256=84fd40aff5f6ed745518c736e379900d6bf4e1197d7329e57c39e21c0f36137d  ;; \
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
    LIGHTNINGD_VERSION=v24.11.1

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
    PYTHON_VERSION_FULL=3.11 \
    PIP_ROOT_USER_ACTION=ignore \
    POETRY_VERSION=1.8.5 \
    RUST_VERSION=1.82

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
        jq \
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
        python${PYTHON_VERSION}-pip \
        qemu-user-static \
        unzip \
        wget \
        tclsh \
        zlib1g \
        zlib1g-dev && \
        update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION_FULL} 1 && \
        { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || rm /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; } && \
        pip3 install --upgrade pip setuptools wheel

# su-exec
RUN mkdir /tmp/su-exec && cd /tmp/su-exec && \
      wget -q --timeout=60 --waitretry=0 --tries=8 -O su-exec.c "https://raw.githubusercontent.com/ncopa/su-exec/master/su-exec.c" && \
      mkdir -p /tmp/su-exec_install/usr/local/bin && \
      SUEXEC_BINARY="/tmp/su-exec_install/usr/local/bin/su-exec" && \
      gcc -Wall su-exec.c -o"${SUEXEC_BINARY}" && \
      chown root:root "${SUEXEC_BINARY}" && \
      chmod 0755 "${SUEXEC_BINARY}"

# rust
ENV RUST_PROFILE=release \
    CARGO_OPTS=--profile=release \
    PATH=$PATH:/root/.cargo/bin
RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain=${RUST_VERSION} --component=rustfmt

# poetry
RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors -sSL https://install.python-poetry.org | POETRY_VERSION=${POETRY_VERSION} python${PYTHON_VERSION} - && \
      /root/.local/bin/poetry self add poetry-plugin-export

RUN export PATH="/root/.local/bin:$PATH" && \
      cd /tmp && \
      git clone --recursive --depth 1 --branch ${LIGHTNINGD_VERSION} https://github.com/ElementsProject/lightning && \
      cd /tmp/lightning && \
      poetry export -o requirements.txt --without-hashes --with dev && \
      pip3 install -r requirements.txt && pip3 cache purge && \
      poetry lock --no-update && \
      poetry install && \
      git reset --hard HEAD && \
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
      poetry export -o requirements.txt --without-hashes --with dev && \
      ( cd plugins/clnrest && poetry export -o requirements.txt --without-hashes ) && \
      ( cd plugins/wss-proxy && poetry export -o requirements.txt --without-hashes )

# CLBOSS
ARG CLBOSS_GIT_HASH=c4e56149b3f0887bb09f3158d17f2386ebd6c36c
RUN apt-get install -qq -y --no-install-recommends \
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
      echo && autoreconf -f -i && \
      ./configure --prefix=/usr/local && \
      make -j$( [ ${MAKE_NPROC} -gt 0 ] && echo ${MAKE_NPROC} || nproc) && \
      make DESTDIR=/tmp/clboss_install install


# - python-builder -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:bookworm-slim as python-builder

ARG MAKE_NPROC=0 \
    LIGHTNINGD_VERSION=v24.11.1

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
    PYTHON_VERSION_FULL=3.11 \
    PIP_ROOT_USER_ACTION=ignore \
    RUST_VERSION=1.82

RUN apt-get install -qq -y --no-install-recommends \
        autoconf \
        automake \
        build-essential \
        curl \
        git \
        libtool \
        libffi-dev \
        libssl-dev \
        pkg-config \
        python${PYTHON_VERSION_FULL} \
        python${PYTHON_VERSION}-dev \
        python${PYTHON_VERSION}-pip

ENV RUST_PROFILE=release \
    CARGO_OPTS=--profile=release \
    PATH=$PATH:/root/.cargo/bin

COPY --from=builder /tmp/lightning /tmp/lightning/

RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain=${RUST_VERSION} --component=rustfmt && \
      { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || rm /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; } && \
      pip3 install --upgrade pip setuptools wheel && \
      ( cd /tmp/lightning && pip3 install -r requirements.txt ) && \
      ( cd /tmp/lightning/plugins/clnrest && pip3 install -r requirements.txt ) && \
      ( cd /tmp/lightning/plugins/wss-proxy && pip3 install -r requirements.txt ) && \
      pip3 cache purge

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

ARG LIGHTNINGD_VERSION=v24.11.1 \
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

COPY --from=builder /tmp/lightning/ /tmp/lightning/
COPY --from=node-builder /tmp/RTL_install/ /

ENV PYTHON_VERSION=3 \
    PYTHON_VERSION_FULL=3.11 \
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
        binutils \
        dnsutils \
        libev-dev \
        libcurl4-gnutls-dev \
        libsqlite3-dev \
        libunwind-dev && \
    apt-get auto-clean && \
    rm -rf /var/lib/apt/lists/* && \
    { [ ! -f /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED ] || rm /usr/lib/python${PYTHON_VERSION_FULL}/EXTERNALLY-MANAGED; } && \
    update-alternatives --install /usr/bin/python python /usr/bin/python${PYTHON_VERSION_FULL} 1 && \
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

COPY ./entrypoint.sh /entrypoint.sh
COPY ./gossip-store-watcher.sh /usr/local/bin/gossip-store-watcher.sh
COPY ./RTL-Config.json ${LIGHTNINGD_HOME}/.config/RTL/RTL-Config.json
RUN chmod 0755 /entrypoint.sh && \
      chmod 0755 /usr/local/bin/gossip-store-watcher.sh && \
      chown -R -h lightning:lightning "${LIGHTNINGD_HOME}"

COPY --from=builder /tmp/su-exec_install/ /
COPY --from=builder /tmp/lightning_install/ /
COPY --from=builder /tmp/clboss_install/ /
COPY --from=python-builder /usr/local/lib/python${PYTHON_VERSION_FULL}/dist-packages/ /usr/local/lib/python${PYTHON_VERSION_FULL}/dist-packages/
COPY --from=downloader /opt/bitcoin/bin /usr/bin
COPY --from=downloader /opt/litecoin/bin /usr/bin
COPY --from=downloader "/tini" /usr/bin/tini

WORKDIR "${LIGHTNINGD_HOME}"

VOLUME "${LIGHTNINGD_HOME}/.config/lightning"
VOLUME "${LIGHTNINGD_DATA}"
EXPOSE ${LIGHTNINGD_PORT} ${LIGHTNINGD_RPC_PORT} ${C_LIGHTNING_REST_PORT} ${C_LIGHTNING_REST_DOCPORT} ${RTL_PORT}

ENTRYPOINT  [ "/usr/bin/tini", "--", "/entrypoint.sh" ]
CMD ["lightningd"]
