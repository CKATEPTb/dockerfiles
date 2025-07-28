FROM --platform=$TARGETOS/$TARGETARCH debian:12.5-slim

LABEL org.opencontainers.image.source="https://github.com/CKATEPTb/dockerfiles"
LABEL org.opencontainers.image.licenses=MIT

# Задаём рабочую директорию
WORKDIR /home

# Установка зависимостей
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl unzip sed chromium xvfb libnspr4 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Добавляем пользователя container
RUN useradd -m -d /home/container container

# Подготавливаем папку и символическую ссылку
RUN mkdir -p /home/container \
    && ln -s /home/container /home/lampac \
    && chown -R container:container /home/container

# Установка ffprobe
RUN curl -L -k -o ffprobe.zip https://github.com/ffbinaries/ffbinaries-prebuilt/releases/download/v6.1/ffprobe-6.1-linux-64.zip \
    && unzip -o ffprobe.zip -d /usr/bin \
    && chmod +x /usr/bin/ffprobe \
    && rm -f ffprobe.zip

# Установка .NET
RUN curl -fSL -k -o dotnet.tar.gz https://dotnetcli.azureedge.net/dotnet/aspnetcore/Runtime/6.0.28/aspnetcore-runtime-6.0.28-linux-x64.tar.gz \
    && mkdir -p /usr/share/dotnet \
    && tar -oxzf dotnet.tar.gz -C /usr/share/dotnet \
    && rm dotnet.tar.gz

# Загрузка Lampac
RUN curl -L -k -o publish.zip https://github.com/immisterio/Lampac/releases/latest/download/publish.zip \
    && unzip -o publish.zip -d /home/container \
    && rm -f publish.zip \
    && rm -rf /home/container/merchant \
    && rm -rf /home/container/runtimes/os* \
    && rm -rf /home/container/runtimes/win* \
    && rm -rf /home/container/runtimes/linux-arm* \
    && rm -rf /home/container/runtimes/linux-musl-* \
    && touch /home/container/isdocker \
    && chown -R container:container /home/container

# Обновление Lampac
RUN curl -k -s https://raw.githubusercontent.com/immisterio/Lampac/main/Build/Docker/update.sh | bash

# Загрузка TorrServer
RUN mkdir -p /home/container/torrserver \
    && curl -L -k -o /home/container/torrserver/TorrServer-linux https://github.com/YouROK/TorrServer/releases/latest/download/TorrServer-linux-amd64 \
    && chmod +x /home/container/torrserver/TorrServer-linux \
    && chown -R container:container /home/container/torrserver

# Установка кастомного NodeJS для Playwright
RUN mkdir -p /home/container/.playwright/node/linux-x64 \
    && curl -L -k -o /home/container/.playwright/node/linux-x64/node https://github.com/immisterio/playwright/releases/download/chrome/node-linux-x64 \
    && chmod +x /home/container/.playwright/node/linux-x64/node \
    && chown -R container:container /home/container/.playwright

# Конфиг и права
RUN echo '{"chromium":{"executablePath":"/usr/bin/chromium"}}' > /home/container/init.conf \
    && chown container:container /home/container/init.conf

# Скачиваем entrypoint
RUN curl -fsSL https://raw.githubusercontent.com/pterodactyl/yolks/refs/heads/master/java/entrypoint.sh -o /entrypoint.sh \
    && chmod +x /entrypoint.sh

# Установка переменных окружения и переключение на пользователя container
USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

CMD [ "/bin/bash", "/entrypoint.sh" ]
