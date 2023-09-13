# docker-core-lightning
Dockerfile with multi-platorm support (linux/amd64, linux/arm64, and linux/arm32
v7) for building a container with core-lightning and clboss.

# Status
This is a work in progress, but it might already be useful - for inspiration at
least.

For now it is assumed that you know your way around containers and core
lightning. In the future there might be configuration that enables things to
work out of the box.

Currently, building for the platforms linux/amd64 and linux/arm64 have been
tested.

# Building
I for one usually build my images with Podman (Buildah) these days. So, these
in structions assume you do as well.

If you just want to build an image for the same architechture that your build
host has there ought be no need for extra steps, and you can just build with
e.g.:

```
$ ( export BUILDAH_FORMAT='docker' && \
      buildah bud --pull --layers --manifest local/core-lightning:latest . )
```

However, if you want to cross-build, you'll need to install QEMU user emulation
and binfmt support.

After that, you ought be able to cross-build your image (e.g. for linux/arm64)
with:

```
$ ( export BUILDAH_FORMAT='docker' && \
      buildah bud --platform linux/arm64 \
        --pull --layers --manifest local/core-lightning:latest . )
```

## On some systems however additional steps might be necessary
Download
https://raw.githubusercontent.com/qemu/qemu/master/scripts/qemu-binfmt-conf.sh
(Assuming you have a recent version of QEMU. If you don't, you might need to
get that file from an older release branch.):

`$ wget "https://raw.githubusercontent.com/qemu/qemu/master/scripts/qemu-binfmt-conf.sh"`

Make it executable:

`$ chmod 0755 qemu-binfmt-conf.sh`

Unregister any existing QEMU binfmts (as root):

```
# ( for f in /proc/sys/fs/binfmt_misc/qemu-*; do \
       [[ ! -e "${f}" ]] || echo '-1' > "${f}"; done )
```

Register the new QEMU binfmts using `qemu-binfmt-conf.sh` (as root):

`# ./qemu-binfmt-conf.sh --qemu-path /usr/bin --persistent yes`

If your QEMU user emulation binaries have been statically built you might need
to instead run (as root):

```
# ./qemu-binfmt-conf.sh --qemu-suffix -static \
     --qemu-path /usr/bin --persistent yes
```

In the above it's assumed that your QEMU binaries reside in `/usr/bin`. If they
do not, you'll need to adjust the `--qemu-path` parameter.

If you were unable to cross-build before, you should be able to now.

# Running

## Bind Address
Contrary to the usual non-containarized case, you'll want to set
`lightningd.conf`'s `bind-addr` to bind to all interfaces in the container.

E.g. `bind-addr=0.0.0.0:9735`.

The access to this port is then restricted by the way you map this
conainer port. For example, adding a `-p 127.0.0.1:9735:9735` to the
`docker run` command will only allow access to that port via the host's
loopback interface.

If you aim to be connectable via clearnet, allowing wide access to that port
by binding it to your network interface - or all interfaces
(e.g. `-p 0.0.0.0:9735:9735`) - makes sense (as opposed to just binding to
`127.0.0.1`).

Setting `bind-addr=127.0.0.1` in the container's `lightningd.conf` will make
the core lightning daemon only bind to the container's loopback interface.

That is a valid setting, but then extra steps need to be taken in order to
make that port accessible to whatever should be able to access it.

## Exposing Core Lightning's RPC socket
By setting the docker environment variable `EXPOSE_TCP_RPC` to `true`
a socat process is started that maps Core Lightning's RPC socket to
TCP port 9835. This port can the be exposed by adding a
`-p 127.0.0.1:9835:9835` to the `docker run` command.

## Wiring stuff in
To run, you'll need to wire in a few things.

### Persistent storage
Assuming that the Debian-based image is used, mapping a host directory to
`/home/lightning/.lightning` in the container is sufficient.
E.g., by adding a
`-v "${HOME}/.lightning":"/home/lightning/.lightning"`
to your `docker run` command.

If you wire in additional plugins, do see to it that plugins written in Rust or
C are statically built. Go plugins are always statically built, and Python
plugins need not to be worried about (unless you do something exotic like
pre-generating byte code).

### Crypto daemon
For the bitcoin network, this would be your bitcoin daemon.
We assume that this is what is wanted. For litecoin the approach is analogous.

There are several ways to do this. Here we list two:

* Setting `bitcoin-rpcconnect` and `bitcoin-rpcport` in your `lightningd.conf`
  to something that can be reached from within the container. One would use
  this approach with a docker network, where the crypto daemon is in the same
  network. One could also use this approach to point
  `bitcoin-rpcconnect` to something like `host.docker.internal`.
* Setting `NETWORK_RPCD=<crypto_daemon_host>:<crypto_daemon_port>`
  as a docker environment variable will start a socat process mapping
  that address to `127.0.0.1:8332` in the containner. This way
  `bitcoin-rpcconnect` and `bitcoin-rpcport` can be set to their common
  values; `127.0.0.1` and `8332`, respectively.

In addition to wiring access to the daemon in, you also need to set
`bitcoin-rpcuser` and `bitcoin-rpcpassword` to the username and password
combination that the bitcoin daemon expects.

### Tor
To have access to a Tor daemon in the container you need to wire that in as
well.

Here there are multiple options as well, that are dependent on how you use
Tor.

There is support for wiring in access to the Tor deamon using socat processes.
This is enabled by setting the docker environment variables `TOR_SOCKSD` and
`TOR_CTRLD`. Both of these are expected to be formatted as `<host>:<port>`.
That makes maps these addresses to `127.0.0.1:9050` and `127.0.0.1:9051`,
respectively.

If you have your hidden service declared in your `torrc`, have
`lightningd.conf`'s `addr` setting independent of Tor, and only use Tor as
a proxy setting `TOR_SOCKSD` is sufficient as the control connection is not
needed in this case.

Depending on which solution you need, you'll need to set
`addr` to point to the control port of the Tor daemon and `proxy` to its socks
port.

## docker run example (for the Debian-based x86_64 image)
```
$ docker run --name core-lightning --restart=no --network=bridge -d \
    -e EXPOSE_TCP_RPC=true \
    -v "${HOME}/.lightning":"/home/lightning/.lightning" \
    -p 127.0.0.1:9835:9835 -p 0.0.0.0:9735:9735 \
    --add-host=host.docker.internal:host-gateway \
    -e NETWORK_RPCD=host.docker.internal:8332 \
    -e TOR_SOCKSD=host.docker.internal:9050 \
    -e TOR_CTRLD=host.docker.internal:9150 \
    local/core-lightning:amd64-latest
```

## docker-compose
There is a `docker-compose.xml` that can be used for inspiration.

## CLBOSS
To use clboss, add

`plugin=/usr/local/bin/clboss`

together with other clboss configuration (if any) to your wired-in core
lightning config. Remember that clboss is included in the image, and so
`/usr/local/bin/clboss` is not referring to your local filesystem.

## Future work (feel free to make pull requests)
* Add sensible `lightningd.conf` that should work out of the box.
* Add and auto-setup RTL for easy interaction with Core Lightning.
* Add images to image repository for others to download.
* Add reference to containerized Bitcoin daemon and provide instructions for interoperation.
* Add reference to containerized Tor daemon and provide instructions for interoperation.
