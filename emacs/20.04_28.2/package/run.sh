#!/bin/sh
docker run -v /root/provision/emacs/20.04_28.2/package:/opt -it caapi/emacs:package_28.2_20.04 /bin/bash
