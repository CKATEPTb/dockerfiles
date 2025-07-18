FROM --platform=$TARGETOS/$TARGETARCH eclipse-temurin:21-jdk-noble

ENV DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.licenses=MIT

# --- Установка MongoDB 8 Community (Ubuntu 24.04 Noble) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    gnupg \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir /docker-entrypoint-initdb.d

RUN wget -qO - https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /etc/apt/keyrings/mongodb.asc && \
    echo "deb [ signed-by=/etc/apt/keyrings/mongodb.asc ] http://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list

ENV MONGO_VERSION 8.0.11

RUN apt-get update && apt-get install -y \
    mongodb-org=$MONGO_VERSION \
    mongodb-org-server=$MONGO_VERSION \
    mongodb-org-shell=$MONGO_VERSION \
    mongodb-org-mongos=$MONGO_VERSION \
    mongodb-org-tools=$MONGO_VERSION \
    && rm -rf /var/lib/apt/lists/*

ENV GLIBC_TUNABLES glibc.pthread.rseq=0
# --- Конец блока MongoDB ---

# --- Установка нужных пакетов и библиотек ---
RUN apt-get update && apt-get install -y \
    curl \
    lsof \
    openssl \
    git \
    tar \
    sqlite3 \
    fontconfig \
    tzdata \
    iproute2 \
    libfreetype6 \
    tini \
    zip \
    unzip \
    jq \
    ffmpeg \
    libvpx-dev \
    libwebp-dev \
    libvorbis0a \
    libopus0 \
    libogg0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    libglib2.0-0 \
    libxcb-shm0 \
    libxcb-xfixes0 \
    libxcb-shape0 \
    libxcb-render-util0 \
    libxcb1 \
    libx11-6 \
    libopenblas0 \
    libopenblas-dev \
    netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*

# --- Настройка пользователя и рабочей директории ---
RUN useradd -d /home/container -m container -s /bin/bash
USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

STOPSIGNAL SIGINT

RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
