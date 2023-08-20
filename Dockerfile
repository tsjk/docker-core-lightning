# This dockerfile is meant to compile a core-lightning image with clboss
# It is using multi stage build:
# * downloader: Download litecoin/bitcoin and qemu binaries needed for core-lightning
# * builder: Compile core-lightning dependencies, then core-lightning itself with static linking
# * final: Copy the binaries required at runtime
# From the root of the repository, run "docker build -t yourimage:yourtag ."

# - downloader -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:bookworm-slim as downloader

ARG BUILDPLATFORM
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
    update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN set -ex \
	&& apt-get update \
	&& apt-get install -qq --no-install-recommends ca-certificates dirmngr wget

WORKDIR /opt

# install tini binary
ENV TINI_VERSION=v0.18.0
RUN { case ${TARGETPLATFORM:-${BUILDPLATFORM}} in \
         "linux/amd64")   TINI_ARCH=amd64; TINI_SHA256SUM=eadb9d6e2dc960655481d78a92d2c8bc021861045987ccd3e27c7eae5af0cf33  ;; \
         "linux/arm64")   TINI_ARCH=arm64; TINI_SHA256SUM=ce3f642d73d58d7c8d745e65b5a9b5de7040fbfa1f7bee2f6207bb28207d8ca1  ;; \
         "linux/arm32v7") TINI_ARCH=armhf; TINI_SHA256SUM=efc2933bac3290aae1180a708f58035baf9f779833c2ea98fcce0ecdab68aa61  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM:-${BUILDPLATFORM}}."; exit 1  ;; \
      esac; } \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O /tini \
         "https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-static-${TINI_ARCH}" \
    && echo "${TINI_SHA256SUM}  /tini" | sha256sum -c - \
    && chmod +x /tini

# install bitcoin binaries
ARG BITCOIN_VERSION=23.0
RUN { case ${TARGETPLATFORM:-${BUILDPLATFORM}} in \
         "linux/amd64")   BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz  ;; \
         "linux/arm64")   BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-aarch64-linux-gnu.tar.gz  ;; \
         "linux/arm32v7") BITCOIN_TARBALL=bitcoin-${BITCOIN_VERSION}-arm-linux-gnueabihf.tar.gz  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM:-${BUILDPLATFORM}}."; exit 1  ;; \
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
ENV LITECOIN_VERSION=0.21.2.2
RUN { case ${TARGETPLATFORM:-${BUILDPLATFORM}} in \
         "linux/amd64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-x86_64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=d53d429d4a0e36670df3d6c5c4eadfca6aac3d4b447a23106cfd490cfc77e9f2  ;; \
         "linux/arm64")   LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-aarch64-linux-gnu.tar.gz; \
                          LITECOIN_SHA256=cd2fb921bdd4386380ea9b9cb949d37f17764eaac89b268751da5ac99e8003c1  ;; \
         "linux/arm32v7") LITECOIN_TARBALL=litecoin-${LITECOIN_VERSION}-arm-linux-gnueabihf.tar.gz; \
                          LITECOIN_SHA256=debd14da7796dcf9bb96ca0e2c7ca3bc6a4d5907b5b9e2950e66d0980a96610b  ;; \
         *) echo "ERROR: Unsupported TARGETPLATFORM: ${TARGETPLATFORM:-${BUILDPLATFORM}}."; exit 1  ;; \
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

ARG LIGHTNINGD_VERSION=v23.05.2 \
    DEVELOPER=1 \
    EXPERIMENTAL_FEATURES=1 \
    CLBOSS_GIT_HASH=ef5c41612da0d544b0ed1f3e986b4b07126723a1

ENV DEBIAN_FRONTEND noninteractive

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update -qq && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

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
        python3-dev \
        python3-mako \
        python3-pip \
        python3-setuptools \
        python3-venv \
        python3.11 \
        qemu-user-static \
        wget\
        zlib1g \
        zlib1g-dev

ENV RUST_PROFILE=release \
    PATH=$PATH:/root/.cargo/bin
RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    rustup toolchain install stable --component rustfmt --allow-downgrade

ENV PYTHON_VERSION=3 \
    PIP_ROOT_USER_ACTION=ignore
RUN curl --connect-timeout 5 --max-time 15 --retry 8 --retry-delay 0 --retry-all-errors -sSL https://install.python-poetry.org | python3 - && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 && \
    rm /usr/lib/python3.11/EXTERNALLY-MANAGED && \
    pip3 install --upgrade pip setuptools wheel && \
    pip3 wheel cryptography && \
    pip3 install grpcio-tools

RUN cd /tmp && \
    git clone --recursive --depth 1 --branch ${LIGHTNINGD_VERSION} https://github.com/ElementsProject/lightning && \
    cd /tmp/lightning && \
    wget -q --timeout=60 --waitretry=0 --tries=8 \
      -O ./pyproject.toml 'https://raw.githubusercontent.com/ElementsProject/lightning/9f1e1ada2a0274db982a59d912313e3e9684a32b/pyproject.toml' && \
    wget -q --timeout=60 --waitretry=0 --tries=8 \
      -O ./poetry.lock 'https://raw.githubusercontent.com/ElementsProject/lightning/9f1e1ada2a0274db982a59d912313e3e9684a32b/poetry.lock' && \
    /root/.local/bin/poetry install && \
    ./configure --prefix=/usr/local \
      --$( [ ${DEVELOPER} -ne 0 ] && echo enable || echo disable)-developer \
      --$( [ ${EXPERIMENTAL_FEATURES} -ne 0 ] && echo enable || echo disable)-experimental-features \
      --disable-address-sanitizer \
      --disable-compat \
      --disable-fuzzing \
      --disable-ub-sanitize \
      --disable-valgrind \
      --enable-rust \
      --enable-static && \
    make && \
    /root/.local/bin/poetry run make DESTDIR=/tmp/lightning_install install && \
    { [ ! -d ./plugin/clnrest ] || pip3 install -r ./plugins/clnrest/requirements.txt; } && \
    { [ ! -d ./contrib/pyln-client ] || pip3 install ./contrib/pyln-client; }

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
    make && \
    make DESTDIR=/tmp/clboss_install install


# - final -
FROM --platform=${TARGETPLATFORM:-${BUILDPLATFORM}} debian:bookworm-slim as final

ARG LIGHTNINGD_UID=1001
ENV LIGHTNINGD_HOME=/home/lightning
ENV LIGHTNINGD_DATA=${LIGHTNINGD_HOME}/.lightning \
    LIGHTNINGD_NETWORK=bitcoin \
    LIGHTNINGD_RPC_PORT=9835 \
    LIGHTNINGD_PORT=9735

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

RUN apt-get install -y --no-install-recommends \
        inotify-tools \
        libpq5 \
        python3.11 \
        python3-pip \
        qemu-user-static \
        socat && \
    apt-get install -y --no-install-recommends    `# 'CLBOSS dependencies'` \
        dnsutils \
        libev-dev \
        libcurl4-gnutls-dev \
        libsqlite3-dev && \
    apt-get auto-clean && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --no-log-init --user-group \
      --create-home --home-dir ${LIGHTNINGD_HOME} \
      --shell /bin/bash --uid ${LIGHTNINGD_UID} lightning

COPY --from=builder /tmp/lightning_install/ /
COPY --from=builder /tmp/lightning/tools/docker-entrypoint.sh entrypoint.sh
COPY --from=builder /usr/local/lib/python3.11/dist-packages/ /usr/local/lib/python3.11/dist-packages/
COPY --from=builder /tmp/clboss_install/ /
COPY --from=downloader /opt/bitcoin/bin /usr/bin
COPY --from=downloader /opt/litecoin/bin /usr/bin
COPY --from=downloader "/tini" /usr/bin/tini

USER lightning

RUN mkdir $LIGHTNINGD_DATA && \
    touch $LIGHTNINGD_DATA/config

WORKDIR "${LIGHTNINGD_HOME}"

VOLUME "${LIGHTNINGD_DATA}"
EXPOSE ${LIGHTNINGD_PORT} ${LIGHTNINGD_RPC_PORT}
ENTRYPOINT  [ "/usr/bin/tini", "-g", "--", "./entrypoint.sh" ]
