FROM ubuntu:22.04

ARG HTTP_PROXY 
ARG DEV_USERNAME
ARG USER_UID
ARG USER_GID

ENV DEBIAN_FRONTEND=noninteractive    
ENV http_proxy=${HTTP_PROXY}
ENV https_proxy=${HTTP_PROXY}
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTP_PROXY}
ENV ALL_PROXY=${HTTP_PROXY}
ENV CLANGD_VERSION=21.1.0
ENV CLANGD_HOME=/usr/local/lib/clangd
ENV PATH=${CLANGD_HOME}/bin:${PATH}
ENV TZ=Asia/Shanghai

RUN \
  sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
  sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
  echo 'Acquire::ForceIPv4 "true";' >> /etc/apt/apt.conf.d/1000-force-ipv4-transport && \    
  echo 'Acquire::Retries "100";' >> /etc/apt/apt.conf.d/80-retries && \
  apt-get update -y && \    
  # basics    
  PKGS="software-properties-common build-essential" && \
  apt-get install -y ${PKGS} && \    
  add-apt-repository -y ppa:ubuntu-toolchain-r/ppa && \
  apt-get update -y && \    
  PKGS="vim sudo locales git curl unzip wget zip iputils-ping iproute2 tzdata tree jq" && \    
  PKGS="${PKGS} gdb net-tools telnet cmake ninja-build ccache linux-tools-common linux-tools-generic" && \    
  apt-get install -y ${PKGS} && \    
  locale-gen en_US.UTF-8 && \    
  echo ${TZ} > /etc/timezone && \
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
  dpkg-reconfigure tzdata && \
  # deps
  # PKGS="libgtest-dev libtbb-dev" && \    
  # apt-get install -y ${PKGS} && \    
  apt-get autoclean && apt-get autoremove && \    
  rm -rf /var/lib/apt/lists/*

RUN \
    # clangd
    wget "https://github.com/clangd/clangd/releases/download/${CLANGD_VERSION}/clangd-linux-${CLANGD_VERSION}.zip" -O /tmp/clangd.zip && \
    unzip /tmp/clangd.zip -d ${CLANGD_HOME} && \
    mv ${CLANGD_HOME}/clangd_${CLANGD_VERSION}/* ${CLANGD_HOME} && \
    rm -rf ${CLANGD_HOME}/clangd_${CLANGD_VERSION} && \
    rm -rf /tmp/clangd.zip

RUN \
    # proxy for wget
    echo "use_proxy = on" >> /etc/wgetrc && \
    echo "http_proxy = ${http_proxy}" >> /etc/wgetrc && \
    echo "https_proxy = ${http_proxy}" >> /etc/wgetrc && \
    # misc
    echo "* soft core unlimited" >>/etc/security/limits.conf && \
    mkdir /coredumps && \
    chmod o+rwx /coredumps

RUN \
  # Create the user
  groupadd --gid $USER_GID $DEV_USERNAME \
  && useradd --uid $USER_UID --gid $USER_GID -m $DEV_USERNAME \
  #
  # [Optional] Add sudo support. Omit if you don't need to install software after connecting.
  && echo $DEV_USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$DEV_USERNAME \
  && chmod 0440 /etc/sudoers.d/$DEV_USERNAME

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"

USER $DEV_USERNAME

# unset
ENV http_proxy=
ENV https_proxy=