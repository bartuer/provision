#!/bin/bash
apt-get update
apt-get install -y --no-install-recommends binutils
ldd /opt/emacs-28.2