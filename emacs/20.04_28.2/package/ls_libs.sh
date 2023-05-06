#!/bin/bash

function file_exist {
while IFS= read -r file; do
    test ! -e "$file" && echo "'$file' not found"
done
}

export -f file_exist
cat /opt/lib_files.txt | file_exist