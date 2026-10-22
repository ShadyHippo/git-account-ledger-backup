FROM alpine:3.21

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        git \
        git-lfs \
        jq \
        tzdata \
 && git lfs install --system --skip-repo

COPY bin/ /usr/local/bin/
RUN chmod 0755 \
        /usr/local/bin/common.sh \
        /usr/local/bin/cred-helper \
        /usr/local/bin/backup.sh \
        /usr/local/bin/ledger.sh \
        /usr/local/bin/bundle.sh \
        /usr/local/bin/restore.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/entrypoint.sh

ENV HOME=/tmp \
    ROOT=/data \
    BACKUP_INTERVAL=3600 \
    LEDGER_INTERVAL=900 \
    BUNDLE_INTERVAL=2592000

VOLUME ["/data"]

HEALTHCHECK --interval=30m --timeout=30s --start-period=15m \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["loop"]
