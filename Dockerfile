# Servidor e Web UI vêm dos forks da neoalerta, não do PyPI/releases do upstream.
# Os commits ficam fixados aqui: a imagem só muda quando este arquivo muda, e
# qualquer tag pode ser reconstruída igual. Para atualizar, troque o SHA pelo
# do master do fork (git ls-remote <repo> refs/heads/master) num PR.
ARG SERVER_REPO=https://github.com/neoalerta/alerta.git
ARG SERVER_REF=7f9aaa435ca88318e293a697568d8f89bafe8d80
ARG WEBUI_REPO=https://github.com/neoalerta/alerta-webui.git
ARG WEBUI_REF=17391b6e1a1af97f91d7df885ab113510b157288

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

ENV IMAGE_VERSION=${RELEASE}
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

COPY requirements-docker.txt /app/

# Dependências fixadas pelo próprio fork do servidor (requirements.txt e
# requirements-ci.txt, que traz lxml, pysaml2 e python-ldap). Aqui só entra o
# que é da imagem: uWSGI e o cliente, usado por housekeeping e heartbeats.
# hadolint ignore=DL3013
RUN pip install --no-cache-dir pip virtualenv jinja2 && \
    python3 -m venv /venv && \
    /venv/bin/pip install --no-cache-dir --upgrade setuptools && \
    git init -q /tmp/server && \
    git -C /tmp/server fetch -q --depth 1 "${SERVER_REPO}" "${SERVER_REF}" && \
    git -C /tmp/server checkout -q FETCH_HEAD && \
    /venv/bin/pip install --no-cache-dir \
      --requirement /tmp/server/requirements.txt \
      --requirement /tmp/server/requirements-ci.txt \
      --requirement /app/requirements-docker.txt && \
    /venv/bin/pip install --no-cache-dir /tmp/server && \
    rm -rf /tmp/server
ENV PATH $PATH:/venv/bin

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
