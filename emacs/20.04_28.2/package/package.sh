#!/bin/bash
cat /opt/file_list.txt |tr '\n' '\0'|xargs -0 tar --null --no-recursion -uf /opt/emacs_28.2_20.04.tar