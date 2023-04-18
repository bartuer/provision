FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    gnupg-agent \
    software-properties-common

RUN add-apt-repository ppa:ubuntu-toolchain-r/ppa && \
    apt-get update && \
    apt-get install -y \
    curl \
    autoconf \
    gcc-10 \
    g++-10 \
    libgccjit0 \
    libgccjit-10-dev \
    libjansson4 \
    libjansson-dev \
    aspell \
    aspell-en \
    sbcl \
    r-base \
    git

RUN sed -i 's/# deb-src/deb-src/' /etc/apt/sources.list && \
    apt-get update && \
    apt-get build-dep -y emacs && \
    apt-get clean && \
    apt-get autoremove
    
RUN mkdir -p ~/etc && \
    cd ~/etc && \
    git clone https://github.com/bartuer/dot-emacs.git el && \
    mkdir -p ~/local/src && \
    cd ~/local/src && \
    curl -O https://ftp.gnu.org/gnu/emacs/emacs-28.2.tar.gz && \
    tar -xzf emacs-28.2.tar.gz 

ENV CC=/usr/bin/gcc-10
ENV CXX=/usr/bin/gcc-10
ENV CFLAGS="-O3"
RUN cd ~/local/src/emacs-28.2 && \
    ./autogen.sh && \
    ./configure --prefix=/root/local --with-native-compilation --with-tiff=no --without-dbus --without-xft --without-xpm --without-xim --without-gconf --with-gnutls --with-json --without-mailutils --without-jpeg --without-tiff --without-gif --without-png --without-rsvg --without-lcms2 --without-libsystemd --without-cairo --without-xml2 --without-native-image-api --without-xft --without-harfbuzz --without-libotf --without-toolkit-scroll-bars --without-xaw3d --without-xim --without-xdbe --without-gpm --without-gsettings --without-selinux --without-libgmp --without-kerberos --without-kerberos5 --without-hesiod --with-sound=no  --with-x-toolkit=no --with-x=no

RUN mkdir -p ~/local/share && \
    cd ~/local/src/emacs-28.2 && \
    make -j && make install && \
    mkdir -p ~/local/bin/ && \
    cp ~/etc/el/install/pbcopy.xlicp.sh ~/local/bin/pbcopy && \
    cp ~/etc/el/install/killemacs ~/local/bin/killemacs && \
    cp ~/etc/el/install/quote0 ~/local/bin/quote0

ENV NVM_DIR="/root/.nvm"
RUN curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.32.0/install.sh | bash && \
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  && nvm install 6.0 && \
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  && nvm use 6.0 && npm install -g gulp 

RUN mkdir -p ~/local/share/emacs && \
    ln -s ~/local/share/emacs/28.2 ~/local/share/emacs/current && \
    cd /root && \
    ln -s /root/etc/el/.emacs.el .emacs.el

COPY ./start_emacs.sh /root/start_emacs.sh
COPY ./test_elisp_native_compile.el /root/test_elisp_native_compile.el
WORKDIR /root

