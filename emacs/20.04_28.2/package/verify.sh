#!/bin/bash
tar xf /opt/emacs_28.2_20.04.tar -C /
export NVM_DIR="/root/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
export PATH=/root/local/bin:/root/.nvm/versions/node/v6.0.0/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/opt/conda/bin
/root/local/bin/emacs-28.2 --daemon -nw -fg yellow