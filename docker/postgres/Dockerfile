FROM postgres:latest

# Instala as dependências necessárias e compila o pgvector
RUN apt-get update \
    && apt-get install -y git build-essential postgresql-server-dev-$(pg_config --version | sed 's/[^0-9]*\([0-9]*\).*/\1/') \
    && cd /tmp \
    && git clone --branch v0.5.1 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make \
    && make install \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/pgvector