FROM --platform=$TARGETOS/$TARGETARCH eclipse-temurin:21-jdk-noble

ENV DEBIAN_FRONTEND=noninteractive

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.licenses=MIT


# --- MongoDB 8 установка ---
RUN apt-get update && apt-get install -y ca-certificates gnupg wget && rm -rf /var/lib/apt/lists/*

RUN wget -qO - https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /etc/apt/keyrings/mongodb.gpg

RUN echo "deb [ arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list

RUN apt-get update && apt-get install -y mongodb-org && rm -rf /var/lib/apt/lists/*
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
    libnss3 \
    libnspr4 \
    && rm -rf /var/lib/apt/lists/*

# --- Настройка пользователя и рабочей директории ---
RUN useradd -d /home/container -m container -s /bin/bash
USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

STOPSIGNAL SIGINT

COPY --chown=container:container entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/entrypoint.sh"]
