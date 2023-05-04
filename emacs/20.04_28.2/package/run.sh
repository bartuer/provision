#!/bin/sh
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 /opt/cp_bin.sh
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt ubuntu:20.04 /opt/bin_libs.sh
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 /opt/lib_deps.sh
docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 /opt/ls_files.sh
