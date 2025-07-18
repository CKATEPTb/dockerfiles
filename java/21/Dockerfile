FROM --platform=$TARGETOS/$TARGETARCH ghcr.io/parkervcp/yolks:java_21

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.licenses=MIT

# --- Commons ---
RUN apt-get update && apt-get install -y software-properties-common ca-certificates lsb-release gnupg wget

# --- MariaDB ---
RUN wget -O- https://mariadb.org/mariadb_release_signing_key.asc | apt-key add -
RUN echo "deb [arch=amd64,arm64] http://archive.mariadb.org/mariadb-10.3.39/repo/ubuntu jammy main" \
    > /etc/apt/sources.list.d/mariadb.list
RUN apt-get update && apt-get install -y mariadb-server=1:10.3.39+maria~jammy netcat-traditional

# --- MongoDB 8 ---
RUN wget -qO - https://pgp.mongodb.com/server-8.0.asc | gpg --dearmor -o /etc/apt/keyrings/mongodb.gpg
RUN echo "deb [ arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list
RUN apt update && apt install -y mongodb-org netcat-openbsd

# --- REDIS ---
# TODO

# --- FFMpeg ---
RUN apt install -y ffmpeg libvpx-dev libwebp-dev libvorbis0a libopus0 libogg0

# --- OpenCV ---
RUN apt libsm6 libxext6 libxrender1 libglib2.0-0libxcb-shm0 libxcb-xfixes0 libxcb-shape0 libxcb-render-util0 libxcb1 \
    libx11-6 libopenblas0 libopenblas-dev

# --- Playwright ---
RUN apt libnss3 libnspr4

# --- TRIM ---
RUN rm -rf /var/lib/apt/lists/*
