# docker-core-lightning
Dockerfile with multi-platorm support (linux/amd64, linux/arm64, and linux/arm32
v7) for building a container with core-lightning and clboss.

# Status
This is a work in progress, but it ought already be useful. The author uses
this project to run his Core Lightning node, and it should thus be possible
to do so for others as well.

Although the aim of this project is to just work out of the box, it hasn't
reached a mature state. For now it is assumed that the user knows her way
around containers, Core Lightning and system administration. In the future
these assumptions may be relaxed.

Currently, building for the platforms linux/amd64 and linux/arm64 have been
tested.

The Dockerfile based on Gentoo (`Dockerfile.gentoo`) is much less developed at
the moment. If you want to try this out, go for using the one based on Debian
(`Dockerfile`).

# Building
I for one usually build my images with Buildah these days. So, these
instructions assume you do as well.

If you just want to build an image for the same architechture that your build
host has there ought be no need for extra steps, and you can just build with
e.g.:

```
$ ( export BUILDAH_FORMAT='docker' && \
      buildah bud --pull --layers --tag local/core-lightning:latest . )
```

However, if you want to cross-build, you'll need to install QEMU user emulation
and binfmt support.

After that, you ought be able to cross-build your image (e.g. for linux/arm64
on linux/amd64) with:

```
$ ( export BUILDAH_FORMAT='docker' && \
      buildah bud --platform linux/arm64 \
        --pull --layers --tag local/core-lightning:arm64-latest . )
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

The `build.sh` script in the current repository aims to help with this
additional setup. By running
```
$ ./build.sh --prepare-qemu-only
```

it'll attempt to do the above (by calling `sudo` when needed).

If you were unable to cross-build before, you should be able to now.

# Running in TL;DR-mode
The aim of this project is to get Core Lightning running in a container in a
flexible but easy way. In principle, it should be possible to just build the
image (either with `buildah` or with `docker`), set the `NETWORK_RPCD`
variables in the `docker-compose.yml` file, and then run it all with
`docker compose up`.

The bundled configuration should work out of the box - given that one correctly
sets up the connection to a Bitcoin Daemon with the `NETWORK_RPCD` variables -,
but with this default bundled configuration Core Lightning has clearnet support
only.

If one does have the patience to look over the configuration file, a
recommendation is to start with the following settings:
* `network` (in case one doesn't want to go onto mainnet)
* `wallet` (for making sure that the wallet database location is according to
wishes)
* `alias` (to give an alias for the node)

Users that want Tor support may also want to look at (after having wired in
Tor support - see below):
* `announce-addr-discovered`
* `addr`
* `announce-addr-dns`
* `autolisten`
* `always-use-proxy`
* `disable-dns`

Note that I (the author) use `podman` and `podman-compose`, so it might happen
that some Podman-only stuff have snuck in. Please file a bug in this case.

# Running

## Core Lightning Bind Address
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
Core Lightning's data directory (having the default setting of
`/home/lightning/.lightning`) and one to it's configuration directory
(having the default setting of `/home/lightning/.config/lightning`) in
the container is sufficient. Note that the configuration file name should be
`lightningd.conf`. While the `docker-compose.yml` does define defaults here,
one might want to wire in different directories when migrating an existing
non-containerized setup to a containerized one.  E.g., adding
```
-v "${HOME}/.lightning":"/home/lightning/.lightning" \
    -v "${HOME}/.config/lightning":"/home/lightning/.config/lightning"
```
to the `docker run` command, with the host directories
`"${HOME}/.lightning"` containing Core Lightning's data and
`"${HOME}/.config/lightning"` containing a `lightningd.conf` should be fine.

When wiring in additional plugins, one needs to be mindful about the plugins
being statically built. Python plugins need not to be worried about in this
sense (unless one does something exotic like pre-generating byte code).
In the case of Python plugins, one does need to see to it that all requirements
are available in the container. One way of installing requirements is to use a
`pre-start.d` script (see the section on this below, and the
`examples/.pre-start.d/01-install-python-deps.sh` file).

Some plugins are tricky to compile statically. A solution for such cases
offered here is to start the container with a shell and one-shoot compile the
plugins (dynamically), placing the resulting binaries on persistent storage.
This way the plugins will be linked to the correct libraries, and
recompilation is only needed on library changes (e.g. after major updates to
the base image, such as it being upgraded from Bullseye to Bookworm). Provided
that `docker-compose.yml` has been set up, an interactive shell can be started
by running:
```
docker compose -f docker-compose.yml -f docker-compose.maintenance.yml \
    run --rm core-lightning
```

Doing this for a foreign architecture, for e.g. compiling plugins for a weaker
device on a stronger one, is possible by prepending the above command with
`DOCKER_DEFAULT_PLATFORM=<platform>` - given that an image has been built for
that platform. E.g., if for instance the current platform is say amd64 and one
wants to compile stuff for aarch64:
```
DOCKER_DEFAULT_PLATFORM=linux/aarch64 docker compose -f docker-compose.yml \
    -f docker-compose.maintenance.yml run --rm core-lightning
```

Examples for compiling both Rust and Go plugins can be found in
`examples/compile-rust-plugins.sh` and `examples/compile-go-plugins.sh`,
respectively. In these examples it is thus assumed that
`/home/lightning/.lightning/plugins` resides on persistent storage.

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

In addition to wiring access to the daemon in, you also need to set the
credentials needed for making requests. This can also be done by either
setting the docker environment variables `NETWORK_RPCD_USER` and
`NETWORK_RPCD_PASSWORD` together with `NETWORK_RPCD_AUTH_SET=true`, or by
setting `bitcoin-rpcuser` and `bitcoin-rpcpassword` directly in the
configuration file together with setting the docker environment variable
`NETWORK_RPCD_AUTH_SET` to `false`.

See e.g. [docker-bitcoin-core](https://github.com/tsjk/docker-bitcoin-core)
for how to run a Bitcoin Daemon in a container.

### Tor
To have access to a Tor daemon in the container you need to wire that in as
well.

Here there are multiple options as well, that are dependent on how you use
Tor.

There is support for wiring in access to the Tor deamon using socat processes.
This is enabled by setting the docker environment variables `TOR_SOCKSD` and
`TOR_CTRLD`. Both of these are expected to be formatted as `<host>:<port>`.
These addresses are then mapped to `127.0.0.1:9050` and `127.0.0.1:9051`,
respectively.

If you have your hidden service declared in your `torrc`, have
`lightningd.conf`'s `addr` setting independent of Tor, and only use Tor as
a proxy, setting `TOR_SOCKSD` is sufficient as the control connection is not
needed in this case.

Another option is to set neither `TOR_SOCKSD` nor `TOR_CTRLD`, and instead
setting `addr` to point to the from-container-reachable control port of the Tor
daemon (if control is needed), and `proxy` the from-container-reachable socks
port in Core Lightning's daemon config, respectively.

See e.g. [tor-relay-docker](https://github.com/tsjk/tor-relay-docker) for how
to run a Tor client (or a full-blown relay for that matter) in a container.

#### Tor Authentication
For some Tor operations authentication is needed. This can be supplied either
by setting the docker environment variable `TOR_SERVICE_PASSWORD`, or by
directly setting `tor-service-password` in Core Lightning's daemon config.

## Connecting through a VPN
To be able to protect one's own network while still being able to publish a
clearnet address, the possibility of running Core Lightning via a port-
forwarding-able VPN provider has been added. The specific VPN provider that
should work pretty much out of the box, is ProtonVPN - but the configuration
ought to be easily adaptable to other providers.

For the easiest setup, the extra component required in this context is
[protonvpn-docker](https://github.com/tsjk/protonvpn-docker). That sets up a
ProtonVPN connection in a separate container, which can then be used by the
current one. Refer to the `docker-compose.vpn.yml` file for a workable
template.

## .env.d
Files in the `${LIGHTNINGD_DATA}/.env.d` are sourced by the root user in the
container before Core Lightning is started. While one can do anything in such
files, the intended use case is to set/override environment variables.

Perhaps one wants to one-shoot-install python packages to a prefix pointing to
persistent storage and then update `PYTHONPATH` to include that prefix.

## .pre-start.d
Executable files with the `.sh` suffix in the `${LIGHTNINGD_DATA}/.pre-start.d`
directory are executed by the root user in the container before Core Lightning
is started. If a script ought be executed by a different user, one can always
`su` that user in the script.

Suitable use cases include installing plugin dependencies, and carrying out
other chores.

## .post-start.d
Executable files with the `.sh` suffix in the
`${LIGHTNINGD_DATA}/.post-start.d` directory are executed by the root user in
the container after Core Lightning has started. If a script ought be executed
by a different user, one can always `su` that user in the script.

Suitable use cases include carrying out chores that require a running
Core Lightning deamon.

## CLBOSS
To use clboss, add

`plugin=/usr/local/bin/clboss`

together with other clboss configuration (if any) to your wired-in core
lightning config. Remember that clboss is included in the image, and so
`/usr/local/bin/clboss` is not referring to your local filesystem.

Note that this is the default in the bundled configuration file.

## Core-Lightning-REST & Ride The Lightning
Core-Lightning-REST & Ride The Lightning are automatically set up.

By default Ride The Lightning should be exposed on port 3000, but one may want
to limit access to `127.0.0.1:3000` (as in the running example below). The port
is configurable by the `RTL_PORT` environment variable.

Core-Lightning-REST, which RTL depends on, need not be exposed if it's not
needed for something else. By default its REST and DOC ports are pre-configured
to be on 49836 and 49837, respectively. These ports are also user configurable
using the environment variables `C_LIGHTNING_REST_PORT` and
`C_LIGHTNING_REST_DOCPORT`.

Authentication details are autogenerated, and one gets the Ride The Lightning
password from the container logs.

It is also possible to wire in configuration files; for Core-Lightning-REST
they should be wired in to `${LIGHTNINGD_HOME}/.config/c-lightning-REST`,
while RTL's should be wired in to `${LIGHTNINGD_HOME}/.config/RTL`.
Note that configuration via the environment will cease to work if user
configuration files are wired in.

# Restart support
When running via a VPN like ProtonVPN, which determines the forwarded port
per session, it can happen that the port changes while Core Lightning is
running. There is no support (yet?) for detecting when this happens, but
monitoring for the occurrence is not difficult.

There is however support for automatically getting what the forwarding
address currently is before Core Lightning is started (when `protonvpn-docker`
is used). There is also support for restarting Core Lightning, without
restarting the entire container, so that the a new forwarding address
can quickly be changed to. Quick restarts of this type only works when
`START_IN_BACKGROUND` is set to true, and is carried out by sending a
`HUP`-signal to the bash-process executing `entrypoint.sh` in the container.
See [pdmn-ps.functions](https://gist.github.com/tsjk/3f05a70d2f403d6b062561cee0bae37c)
for inpiration on how to find that process (hopefully this can be made easier
in the future).

## docker run example (for the Debian-based image)
Assuming that the current working directory is the top level of the clone of
this repository and that the image built only has the `latest` tag,
a reasonable example ought to be:
```
$ docker run --rm --name core-lightning --restart=no --network=bridge -d \
    -e EXPOSE_TCP_RPC=true \
    -v "lightning":"/home/lightning/.lightning" \
    -v "config-lightning":"/home/lightning/.config/lightning" \
    -p 127.0.0.1:9835:9835 -p 0.0.0.0:9735:9735 -p 127.0.0.1:3000:3000 \
    --add-host=host.docker.internal:host-gateway \
    -e NETWORK_RPCD=host.docker.internal:8332 \
    -e NETWORK_RPCD_AUTH_SET=true \
    -e NETWORK_RPCD_USER="<USER>" \
    -e NETWORK_RPCD_PASSWORD="<PASSWORD>" \
    core-lightning:latest
```

This would start Core Lightning with CLBOSS, Core-Lightning-REST and
Ride The Lightning enabled, but with only clearnet support
(as `TOR_SOCKSD`, `TOR_CTRLD` and `TOR_SERVICE_PASSWORD` are unset).

## docker-compose
There is template `docker-compose.yml` with some comments that aim to help
with getting started.

## Future work (feel free to make pull requests)
* Upgrade Core Lightning to the v23.08 series.
* Make it easier to respond to changes to the port-forwarding address.
* Add images to image repository for others to download (although the image
is quite large, so perhaps this will remain as a build-it-yourself image).
