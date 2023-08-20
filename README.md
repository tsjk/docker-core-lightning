# docker-core-lightning
Dockerfile with multi-platorm support for building a container with core-lightning and clboss.

# Status
This is a work in progress, but it might already be useful - for inspiration at least.

For now it is assumed that you know your way around containers and core lightning.
You'll need to be able to wire in persistant storage, your configs and additional plugins (if any). There is also, as of yet, neither help for gluing this together with your bitcoin daemon nor, if needed, your Tor daemon.
In the future there might be configuration that enables things to work out of the box.

Currently, building for the platforms linux/amd64 and linux/arm64 have been tested.

# Building
I for one usually build my images with Podman (Buildah) these days. So, these instructions assume you do as well.

If you just want to build an image for the same architechture that your build host has there ought be no need for extra steps, and you can just build with e.g.:

```
$ ( export BUILDAH_FORMAT='docker' && \
      buildah bud --pull --layers --manifest local/core-lightning:latest . )
```

However, if you want to cross-build, you'll need to install QEMU user emulation and binfmt support.

After that, you ought be able to cross-build your image (e.g. for linux/arm64) with:

```
$ ( export BUILDAH_FORMAT='docker' && \
      buildah bud --platform linux/arm64 --pull --layers --manifest local/core-lightning:latest . )
```

## On some systems however additional steps might be necessary
Download https://raw.githubusercontent.com/qemu/qemu/master/scripts/qemu-binfmt-conf.sh (Assuming you have a recent version of QEMU. If you don't, you might need to get that file from an older release branch.):

`$ wget "https://raw.githubusercontent.com/qemu/qemu/master/scripts/qemu-binfmt-conf.sh"`

Make it executable:

`$ chmod 0755 qemu-binfmt-conf.sh`

Unregister any existing QEMU binfmts (as root):

`# ( for f in /proc/sys/fs/binfmt_misc/qemu-*; do [[ ! -e "${f}" ]] || echo '-1' > "${f}"; done )`

Register the new QEMU binfmts using `qemu-binfmt-conf.sh` (as root):

`# ./qemu-binfmt-conf.sh --qemu-path /usr/bin --persistent yes`

If your QEMU is statically built you might need to instead run (as root):

`# ./qemu-binfmt-conf.sh --qemu-suffix -static --qemu-path /usr/bin --persistent yes`

In the above it's assumed that your QEMU binaries reside in `/usr/bin`. If they do not, you'll need to adjust the `--qemu-path` parameter.

If you were unable to cross-build before, you should be able to now.

# CLBOSS
To use clboss, add

`plugin=/usr/local/bin/clboss`

together with other clboss configuration (if any) to your wired-in core lightning config. Remember that clboss is included in the image, and so `/usr/local/bin/clboss` is not referring to your local filesystem.
