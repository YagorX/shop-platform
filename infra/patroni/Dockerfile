FROM postgres:17-bookworm

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    ca-certificates \
 && pip3 install --break-system-packages --no-cache-dir "patroni[etcd3,psycopg2-binary]" \
 && rm -rf /var/lib/apt/lists/*


COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint.sh
RUN chmod +x /usr/local/bin/patroni-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
CMD ["/etc/patroni/patroni.yml"]
