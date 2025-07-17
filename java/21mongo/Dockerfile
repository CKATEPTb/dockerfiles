FROM        --platform=$TARGETOS/$TARGETARCH eclipse-temurin:21-jdk-noble

LABEL       org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL       org.opencontainers.image.licenses=MIT

# Install mongo 8 - start
RUN apt-get update && apt-get install -y gnupg curl
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-8.0.gpg
RUN echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-8.0.list
RUN apt-get update && apt-get install -y mongodb-org
# Install mongo 8 - end

RUN         apt update -y \
            && apt install -y \
                curl \
                lsof \
                ca-certificates \
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
				# ffmpeg + все кодеки для webm, vp8/vp9, opus, vorbis
				ffmpeg \
				libvpx-dev \
				libwebp-dev \
				libvorbis0a \
				libopus0 \
				libogg0 \
				# для opencv, javacv, bytedeco (X11 стэк)
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
				# для openblas (ускорение математики, для opencv/javacv)
				libopenblas0 \
				libopenblas-dev

## Setup user and working directory
RUN         useradd -m -d /home/container -s /bin/bash container
USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

STOPSIGNAL SIGINT

COPY        --chown=container:container entrypoint.sh /entrypoint.sh
RUN         chmod +x /entrypoint.sh
ENTRYPOINT    ["/usr/bin/tini", "-g", "--"]
CMD         ["/entrypoint.sh"]
