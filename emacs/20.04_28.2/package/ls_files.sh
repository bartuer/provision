#!/bin/bash
apt-get update
apt-get install -y --no-install-recommends parallel
parallel --pipepart /opt/file_list.txt