#!/bin/bash
apt-get update
apt-get install -y --no-install-recommends binutils
ldd /opt/emacs-28.2

function file_exist {
while IFS= read -r file; do
    test ! -e "$file" && echo "'$file' not found"
done
}

export -f file_exist
cat /opt/lib_files.txt | file_exist