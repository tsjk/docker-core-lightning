# docker-core-lightning
Dockerfile with multi-platorm support for building a container with core-lightning and clboss

# Status
This is a work in progress, but it might already be useful - for inspiration at least

# CLBOSS
To use clboss, add

`plugin=/usr/local/bin/clboss`

together with other clboss configuration (if any) to your wired-in core lightning config. Remember that clboss is included in the image, and so `/usr/local/bin/clboss` is not referring to your local filesystem.
