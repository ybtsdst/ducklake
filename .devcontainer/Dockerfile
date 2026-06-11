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
  echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" >> /etc/apt/apt.conf.d/99-proxy && \
  echo "Acquire::https::Proxy \"${HTTPS_PROXY}\";" >> /etc/apt/apt.conf.d/99-proxy && \
  apt-get update -y && \
  # basics    
  PKGS="software-properties-common build-essential" && \
  apt-get install -y ${PKGS} && \    
  add-apt-repository -y ppa:ubuntu-toolchain-r/test && \
  apt-get update -y && \
  PKGS="vim sudo locales git curl unzip wget zip iputils-ping iproute2 tzdata tree jq" && \
  PKGS="${PKGS} gdb net-tools telnet cmake ninja-build ccache linux-tools-common linux-tools-generic" && \
  apt-get install -y ${PKGS} && \
  locale-gen en_US.UTF-8 && \
  echo ${TZ} > /etc/timezone && \
  ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
  dpkg-reconfigure tzdata && \
  # gcc-13: postgres_scanner (fetched by ENABLE_POSTGRES_SCANNER=1) does not
  # compile with jammy's gcc 11 (unique_ptr implicit-move conversions)
  PKGS="gcc-13 g++-13" && \
  apt-get install -y ${PKGS} && \
  update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 60 \
    --slave /usr/bin/g++ g++ /usr/bin/g++-13 \
    --slave /usr/bin/gcov gcov /usr/bin/gcov-13 && \
  # deps
  # libssl-dev: required by postgres_scanner
  # libpq-dev: postgres_scanner needs libpq >= 18 (OAuth API), so take it from PGDG
  install -d /usr/share/postgresql-common/pgdg && \
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt jammy-pgdg main" > /etc/apt/sources.list.d/pgdg.list && \
  apt-get update -y && \
  PKGS="libssl-dev libpq-dev" && \
  apt-get install -y ${PKGS} && \
  apt-get autoclean && apt-get autoremove && \
  rm -rf /var/lib/apt/lists/*

RUN \
  # docker cli
  apt-get update \
  && apt-get install -y ca-certificates curl \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && . /etc/os-release \
  && echo "Types: deb\nURIs: https://download.docker.com/linux/ubuntu\nSuites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}\nComponents: stable\nArchitectures: $(dpkg --print-architecture)\nSigned-By: /etc/apt/keyrings/docker.asc" \
  > /etc/apt/sources.list.d/docker.sources \
  && apt-get update \
  && apt-get install -y docker-ce-cli \
  && rm -rf /var/lib/apt/lists/*

COPY tmp/clangd-linux-21.1.0.zip /tmp/clangd.zip

RUN \
    # clangd
    #wget "https://github.com/clangd/clangd/releases/download/${CLANGD_VERSION}/clangd-linux-${CLANGD_VERSION}.zip" -O /tmp/clangd.zip && \
    unzip /tmp/clangd.zip -d ${CLANGD_HOME} && \
    mv ${CLANGD_HOME}/clangd_${CLANGD_VERSION}/* ${CLANGD_HOME} && \
    rm -rf ${CLANGD_HOME}/clangd_${CLANGD_VERSION} && \
    rm -rf /tmp/clangd.zip

ENV CROARING_VERSION=4.7.1

RUN \
    # CRoaring: required by find_package(roaring CONFIG REQUIRED) for deletion
    # vectors; jammy's libroaring-dev (0.2.66) predates the roaring:: namespace,
    # so build a recent release from source
    git clone --depth 1 --branch v${CROARING_VERSION} https://github.com/RoaringBitmap/CRoaring.git /tmp/croaring && \
    cmake -S /tmp/croaring -B /tmp/croaring/build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DENABLE_ROARING_TESTS=OFF -DROARING_BUILD_C_TESTS_AS_CPP=OFF && \
    cmake --build /tmp/croaring/build -j && \
    cmake --install /tmp/croaring/build && \
    rm -rf /tmp/croaring

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
  # Install Node.js 20.x
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
  apt-get update -y && \
  apt-get install -y nodejs && \
  apt-get autoclean

RUN \
  # Create the user
  groupadd --gid $USER_GID $DEV_USERNAME \
  && useradd --uid $USER_UID --gid $USER_GID -m $DEV_USERNAME \
  #
  # [Optional] Add sudo support. Omit if you don't need to install software after connecting.
  && echo $DEV_USERNAME ALL=\(root\) NOPASSWD:ALL > /etc/sudoers.d/$DEV_USERNAME \
  && chmod 0440 /etc/sudoers.d/$DEV_USERNAME && \
  # add user to docker group
  groupadd -f docker \
  && usermod -aG docker $DEV_USERNAME

ENV LC_ALL="en_US.UTF-8"
ENV LANG="en_US.UTF-8"

USER $DEV_USERNAME

RUN \
  # Install Claude Code in user space for auto-update support
  mkdir -p ~/.npm-global && \
  npm config set prefix ~/.npm-global && \
  npm install -g @anthropic-ai/claude-code

ENV PATH=/home/${DEV_USERNAME}/.npm-global/bin:${PATH}

# unset
ENV http_proxy=
ENV https_proxy=