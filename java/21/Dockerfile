FROM --platform=$TARGETOS/$TARGETARCH ghcr.io/parkervcp/yolks:java_21

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.licenses=MIT

USER root
WORKDIR /

# --- Commons ---
RUN apt-get update && apt-get install -y software-properties-common ca-certificates lsb-release gnupg wget

# --- MariaDB ---
RUN apt-get update && apt-get install -y mariadb-server netcat-openbsd

# --- MongoDB 8 ---
RUN wget -qO - https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /etc/apt/keyrings/mongodb.gpg
RUN echo "deb [ arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list
RUN apt-get update && apt-get install -y mongodb-org netcat-openbsd

# --- REDIS ---
RUN apt-get install -y redis-server

# --- FFMpeg ---
RUN apt-get install -y ffmpeg libvpx-dev libwebp-dev libvorbis0a libopus0 libogg0

# --- OpenCV ---
RUN apt-get install -y libsm6 libxext6 libxrender1 libglib2.0-0 libxcb-shm0 libxcb-xfixes0 libxcb-shape0 \
    libxcb-render-util0 libxcb1 libx11-6 libopenblas0 libopenblas-dev

# --- Playwright ---
# --- Playwright ---
RUN apt-get install -y \
    libnss3 \
    libnspr4 \
    libgtk-4-1 \
    libgraphene-1.0-0 \
    libxslt1.1 \
    libwoff1 \
    libevent-2.1-7 \
    libgstreamer-plugins-base1.0-0 \
    libgstreamer-plugins-good1.0-0 \
    libgstaudio-1.0-0 \
    libgstpbutils-1.0-0 \
    libgsttag-1.0-0 \
    libavif16 \
    libharfbuzz-icu0 \
    libenchant-2-2 \
    libsecret-1-0 \
    libhyphen0 \
    libmanette-0.2-0 \
    libgles2 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly


# --- TRIM ---
RUN rm -rf /var/lib/apt/lists/*

USER container
WORKDIR /home/container
