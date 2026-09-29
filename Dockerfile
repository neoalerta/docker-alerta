# Servidor e Web UI vêm dos forks da neoalerta, não do PyPI/releases do upstream.
# SERVER_REF e WEBUI_REF aceitam branch, tag ou SHA; o CI passa o SHA resolvido
# para o build ser reprodutível e não reaproveitar cache velho de "master".
ARG SERVER_REPO=https://github.com/neoalerta/alerta.git
ARG SERVER_REF=master
ARG WEBUI_REPO=https://github.com/neoalerta/alerta-webui.git
ARG WEBUI_REF=master

FROM node:14-bullseye AS webui

ARG WEBUI_REPO
ARG WEBUI_REF

WORKDIR /src
# O package-lock resolve dependências do GitHub via ssh://; no build não há
# chave SSH, então força HTTPS.
RUN git config --global url."https://github.com/".insteadOf ssh://git@github.com/ && \
    git init -q . && \
    git fetch -q --depth 1 "${WEBUI_REPO}" "${WEBUI_REF}" && \
    git checkout -q FETCH_HEAD && \
    npm ci --no-audit --no-fund && \
    npm run build

FROM python:3.13-slim-bookworm

ARG SERVER_REPO
ARG SERVER_REF
ARG WEBUI_REF

ENV PYTHONUNBUFFERED 1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1
ENV PIP_NO_CACHE_DIR=1

ARG BUILD_DATE
ARG RELEASE
ARG VERSION

ENV SERVER_VERSION=${RELEASE}
ENV SERVER_REF=${SERVER_REF}
ENV CLIENT_VERSION=8.5.3
ENV WEBUI_REF=${WEBUI_REF}

ENV NGINX_WORKER_PROCESSES=1
ENV NGINX_WORKER_CONNECTIONS=1024

ENV UWSGI_PROCESSES=5
ENV UWSGI_LISTEN=100
ENV UWSGI_BUFFER_SIZE=8192
ENV UWSGI_MAX_WORKER_LIFETIME=30
ENV UWSGI_WORKER_LIFETIME_DELTA=3

ENV HEARTBEAT_SEVERITY=major
ENV HK_EXPIRED_DELETE_HRS=2
ENV HK_INFO_DELETE_HRS=12

LABEL org.opencontainers.image.description="Alerta API + Web UI (neoalerta)" \
      org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.url="https://github.com/neoalerta/docker-alerta/pkgs/container/alerta-web" \
      org.opencontainers.image.source="https://github.com/neoalerta/docker-alerta" \
      org.opencontainers.image.version=$RELEASE \
      org.opencontainers.image.revision=$VERSION \
      org.opencontainers.image.licenses=Apache-2.0

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    gnupg2 \
    libldap2-dev \
    libpq-dev \
    libsasl2-dev \
    libxml2-dev \
    libxslt-dev \
    postgresql-client \
    python3-dev \
    supervisor \
    xmlsec1 && \
    apt-get -y clean && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://nginx.org/keys/nginx_signing.key | apt-key add - && \
    echo "deb https://nginx.org/packages/debian/ bookworm nginx" | tee /etc/apt/sources.list.d/nginx.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    nginx && \
    apt-get -y clean && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# hadolint ignore=DL3008
RUN curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | apt-key add - && \
    echo "deb https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    mongodb-mongosh && \
    apt-get -y clean && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

COPY requirements*.txt /app/

# hadolint ignore=DL3013
RUN pip install --no-cache-dir pip virtualenv jinja2 && \
    python3 -m venv /venv && \
    /venv/bin/pip install --no-cache-dir --upgrade setuptools && \
    /venv/bin/pip install --no-cache-dir --requirement /app/requirements.txt && \
    /venv/bin/pip install --no-cache-dir --requirement /app/requirements-docker.txt
ENV PATH $PATH:/venv/bin

RUN /venv/bin/pip install alerta==${CLIENT_VERSION} "git+${SERVER_REPO}@${SERVER_REF}"
COPY install-plugins.sh /app/install-plugins.sh
COPY plugins.txt /app/plugins.txt
RUN /app/install-plugins.sh

COPY --from=webui /src/dist /web

ENV ALERTA_SVR_CONF_FILE /app/alertad.conf
ENV ALERTA_CONF_FILE /app/alerta.conf
ENV ALERTA_WEB_CONF_FILE /web/config.json

COPY config/templates/app/ /app
COPY config/templates/web/ /web

RUN ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

RUN chgrp -R 0 /app /venv /web && \
    chmod -R g=u /app /venv /web && \
    useradd -u 1001 -g 0 -d /app alerta

USER 1001

COPY docker-entrypoint.sh /usr/local/bin/

ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 8080 1717
CMD ["supervisord", "-c", "/app/supervisord.conf"]
