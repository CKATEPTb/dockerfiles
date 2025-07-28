FROM --platform=$TARGETOS/$TARGETARCH debian:12.5-slim

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.licenses=MIT

# Установка зависимостей
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip sed chromium xvfb libnspr4 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Создание пользователя и рабочей директории
RUN useradd -m -d /home/container container

# Скачивание .NET Runtime
RUN curl -fSL -k -o dotnet.tar.gz https://dotnetcli.azureedge.net/dotnet/aspnetcore/Runtime/6.0.28/aspnetcore-runtime-6.0.28-linux-x64.tar.gz \
    && mkdir -p /usr/share/dotnet \
    && tar -oxzf dotnet.tar.gz -C /usr/share/dotnet \
    && rm dotnet.tar.gz

# Установка ffprobe
RUN curl -L -k -o ffprobe.zip https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffprobe-6.1-linux-64.zip \
    && unzip -o ffprobe.zip -d /usr/bin \
    && chmod +x /usr/bin/ffprobe \
    && rm -f ffprobe.zip

# TorrServer бинарник
RUN mkdir -p /opt/torrserver \
    && curl -L -k -o /opt/torrserver/TorrServer-linux https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-amd64 \
    && chmod +x /opt/torrserver/TorrServer-linux

# Playwright Node.js
RUN mkdir -p /opt/playwright/node/linux-x64 \
    && curl -L -k -o /opt/playwright/node/linux-x64/node https://github.com/immisterio/playwright/releases/download/chrome/node-linux-x64 \
    && chmod +x /opt/playwright/node/linux-x64/node

# Chromium конфигурация
RUN echo '{"chromium":{"executablePath":"/usr/bin/chromium"}}' > /opt/init.conf

# entrypoint для pterodactyl yolks
RUN curl -fsSL https://raw.githubusercontent.com/pterodactyl/yolks/refs/heads/master/java/entrypoint.sh -o /entrypoint.sh \
    && chmod +x /entrypoint.sh

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

CMD ["/bin/bash", "/entrypoint.sh"]
