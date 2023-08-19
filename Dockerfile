# This dockerfile is meant to compile a core-lightning x64 image
# It is using multi stage build:
# * downloader: Download litecoin/bitcoin and qemu binaries needed for core-lightning
# * builder: Compile core-lightning dependencies, then core-lightning itself with static linking
# * final: Copy the binaries required at runtime
# The resulting image uploaded to dockerhub will only contain what is needed for runtime.
# From the root of the repository, run "docker build -t yourimage:yourtag ."

# - downloader -
FROM debian:bookworm-slim as downloader

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

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV LC_ALL en_US.UTF-8

RUN set -ex \
	&& apt-get update \
	&& apt-get install -qq --no-install-recommends ca-certificates dirmngr wget

WORKDIR /opt

RUN wget -q --timeout=60 --waitretry=0 --tries=8 -O /tini "https://github.com/krallin/tini/releases/download/v0.18.0/tini" \
    && echo "12d20136605531b09a2c2dac02ccee85e1b874eb322ef6baf7561cd93f93c855 /tini" | sha256sum -c - \
    && chmod +x /tini

ARG BITCOIN_VERSION=23.0
ENV BITCOIN_TARBALL bitcoin-${BITCOIN_VERSION}-x86_64-linux-gnu.tar.gz
ENV BITCOIN_URL https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION/$BITCOIN_TARBALL
ENV BITCOIN_ASC_URL https://bitcoincore.org/bin/bitcoin-core-$BITCOIN_VERSION/SHA256SUMS

RUN mkdir /opt/bitcoin && cd /opt/bitcoin \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O $BITCOIN_TARBALL "$BITCOIN_URL" \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O bitcoin "$BITCOIN_ASC_URL" \
    && grep $BITCOIN_TARBALL bitcoin | tee SHA256SUMS \
    && sha256sum -c SHA256SUMS \
    && BD=bitcoin-$BITCOIN_VERSION/bin \
    && tar -xzvf $BITCOIN_TARBALL $BD/bitcoin-cli --strip-components=1 \
    && rm $BITCOIN_TARBALL

ENV LITECOIN_VERSION 0.21.2.2
ENV LITECOIN_URL https://download.litecoin.org/litecoin-${LITECOIN_VERSION}/linux/litecoin-${LITECOIN_VERSION}-x86_64-linux-gnu.tar.gz
ENV LITECOIN_SHA256 d53d429d4a0e36670df3d6c5c4eadfca6aac3d4b447a23106cfd490cfc77e9f2

# install litecoin binaries
RUN mkdir /opt/litecoin && cd /opt/litecoin \
    && wget -q --timeout=60 --waitretry=0 --tries=8 -O litecoin.tar.gz "$LITECOIN_URL" \
    && echo "$LITECOIN_SHA256  litecoin.tar.gz" | sha256sum -c - \
    && BD=litecoin-$LITECOIN_VERSION/bin \
    && tar -xzvf litecoin.tar.gz $BD/litecoin-cli --strip-components=1 --exclude=*-qt \
    && rm litecoin.tar.gz


# - builder -
FROM debian:bookworm-slim as builder

ARG LIGHTNINGD_VERSION=v23.05.2

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

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV LC_ALL en_US.UTF-8

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

ENV RUST_PROFILE=release
ENV PATH=$PATH:/root/.cargo/bin
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
RUN rustup toolchain install stable --component rustfmt --allow-downgrade

RUN cd /tmp && \
    git clone --recursive https://github.com/ElementsProject/lightning && \
    cd /tmp/lightning && \
    git checkout --recurse-submodules ${LIGHTNINGD_VERSION}

ARG DEVELOPER=1
ARG EXPERIMENTAL_FEATURES=1
ENV PYTHON_VERSION=3 \
    PIP_ROOT_USER_ACTION=ignore
RUN curl -sSL https://install.python-poetry.org | python3 -

RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 && \
      rm /usr/lib/python3.11/EXTERNALLY-MANAGED

RUN pip3 install --upgrade pip setuptools wheel
RUN pip3 wheel cryptography
RUN pip3 install grpcio-tools

RUN cd /tmp/lightning && \
    wget -q --timeout=60 --waitretry=0 --tries=8 \
      -O ./pyproject.toml 'https://raw.githubusercontent.com/ElementsProject/lightning/9f1e1ada2a0274db982a59d912313e3e9684a32b/pyproject.toml' && \
    wget -q --timeout=60 --waitretry=0 --tries=8 \
      -O ./poetry.lock 'https://raw.githubusercontent.com/ElementsProject/lightning/9f1e1ada2a0274db982a59d912313e3e9684a32b/poetry.lock' && \
    /root/.local/bin/poetry install
RUN cd /tmp/lightning && \
    ./configure --prefix=/tmp/lightning_install \
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
    /root/.local/bin/poetry run make install && \
    { [ ! -d ./plugin/clnrest ] || pip3 install -r ./plugins/clnrest/requirements.txt; } && \
    { [ ! -d ./contrib/pyln-client ] || pip3 install ./contrib/pyln-client; }

# CLBOSS
COPY ./clboss-patches /tmp
RUN apt-get install -qq -y --no-install-recommends \
        libev-dev \
        libcurl4-gnutls-dev \
        libsqlite3-dev \
        dnsutils \
        autoconf-archive && \
    cd /tmp && \
    git clone https://github.com/ZmnSCPxj/clboss && \
    cd clboss && \
    git checkout f4a7715ab7e0480c9b73aa34165ff928e89fc2a2 && \
    ( for f in /tmp/clboss-patches/*.patch; do patch -p1 < ${f}; done ) && \
    autoreconf -f -i && \
    ./configure --prefix=/tmp/clboss_install && \
    make && \
    make install


# - final -
FROM debian:bookworm-slim as final

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    echo 'Etc/UTC' > /etc/timezone && \
    dpkg-reconfigure --frontend noninteractive tzdata && \
    apt-get update && \
    apt-get install -qq -y locales && \
    sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    echo 'LANG="en_US.UTF-8"' > /etc/default/locale && \
    dpkg-reconfigure -f noninteractive locales && \
    update-locale LANG=en_US.UTF-8

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV LC_ALL en_US.UTF-8

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
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /tmp/lightning_install/ /usr/local/
COPY --from=builder /tmp/lightning/tools/docker-entrypoint.sh entrypoint.sh
COPY --from=builder /usr/local/lib/python3.11/dist-packages/ /usr/local/lib/python3.11/dist-packages/
COPY --from=builder /tmp/clboss_install/ /usr/local/
COPY --from=downloader /opt/bitcoin/bin /usr/bin
COPY --from=downloader /opt/litecoin/bin /usr/bin
COPY --from=downloader "/tini" /usr/bin/tini

ARG LIGHTNINGD_UID=1001
ENV LIGHTNINGD_HOME=/home/lightning
ENV LIGHTNINGD_DATA=${LIGHTNINGD_HOME}/.lightning
ENV LIGHTNINGD_RPC_PORT=9835
ENV LIGHTNINGD_PORT=9735
ENV LIGHTNINGD_NETWORK=bitcoin

RUN useradd --no-log-init --user-group \
      --create-home --home-dir ${LIGHTNINGD_HOME} \
      --shell /bin/bash --uid ${LIGHTNINGD_UID} lightning

USER lightning

RUN mkdir $LIGHTNINGD_DATA && \
    touch $LIGHTNINGD_DATA/config

WORKDIR "${LIGHTNINGD_HOME}"

VOLUME "${LIGHTNINGD_DATA}"
EXPOSE ${LIGHTNINGD_PORT} ${LIGHTNINGD_RPC_PORT}
ENTRYPOINT  [ "/usr/bin/tini", "-g", "--", "./entrypoint.sh" ]
