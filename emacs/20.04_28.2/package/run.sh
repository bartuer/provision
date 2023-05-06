#!/bin/sh
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 /opt/cp_bin.sh
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt ubuntu:20.04 /opt/bin_libs.sh
# curl https://uswvhd.blob.core.windows.net/learning/ubuntu/20.04/me/x86_64/emacs.tgz |tar zt > file_list.txt
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 find /root/local/lib/emacs/28.2/native-lisp -type f >> file_list.txt
# docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 /opt/ls_files.sh
docker run -v /root/provision/emacs/20.04_28.2/package:/opt caapi/emacs:package_28.2_20.04 /opt/package.sh
docker run -v /root/provision/emacs/20.04_28.2/package:/opt ubuntu:20.04 /opt/verify.sh