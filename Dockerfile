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
RUN chmod 0755 /usr/local/bin/*.sh /usr/local/bin/cred-helper

ENV HOME=/tmp \
    ROOT=/data \
    CONFIG_FILE=/config/config.json \
    SCHEDULE_AT=03:15 \
    RUN_ON_STARTUP=1 \
    BACKUP_INTERVAL=3600 \
    LEDGER_INTERVAL=900 \
    BUNDLE_INTERVAL=2592000 \
    BUNDLE_KEEP=6 \
    VERIFY_INTERVAL=86400

VOLUME ["/data"]

HEALTHCHECK --interval=30m --timeout=30s --start-period=15m \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["loop"]
