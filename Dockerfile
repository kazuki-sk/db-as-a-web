# Dockerfile
FROM postgres:15-alpine

# 日本語ロケール設定 (ログ視認性のため推奨)
ENV LANG ja_JP.utf8

# 1. サーバーロジック (DDL/Functions)
COPY ./sql/init.sql /docker-entrypoint-initdb.d/01_init.sql

# 2. 静的アセット (Data) - コンパイル済みSQL
COPY ./docker/initdb/02_assets.sql /docker-entrypoint-initdb.d/02_assets.sql

# 3. 本番用設定チューニング
# max_connections や shared_buffers を環境に合わせて調整するカスタム設定
COPY ./config/prod.conf /etc/postgresql/postgresql.conf

# デフォルトコマンドをオーバーライドしてカスタム設定を適用
CMD ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf"]
