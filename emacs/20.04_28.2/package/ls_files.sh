#!/bin/bash
apt-get update
apt-get install -y --no-install-recommends parallel

function file_exist {
while IFS= read -r file; do
    test ! -e "$file" && echo "'$file' not found"
done
}

export -f file_exist
# file_exist
parallel --pipepart -a /opt/file_list.txt file_exist