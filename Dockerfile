FROM alpine:3.19

LABEL maintainer="Matt Titmus <matthew.titmus@gmail.com>"
LABEL date="2025-12-05"

# bash/tzdata for your scripts, docker-cli for a modern client, curl for webhooks
RUN apk add --no-cache \
      bash \
      tzdata \
      docker-cli \
      curl \
      ca-certificates \
  && update-ca-certificates

# docker-gc + helper scripts
ADD https://raw.githubusercontent.com/spotify/docker-gc/master/docker-gc /usr/bin/docker-gc
COPY build/default-docker-gc-exclude /etc/docker-gc-exclude
COPY build/executed-by-cron.sh /executed-by-cron.sh
COPY build/generate-crontab.sh /generate-crontab.sh
COPY build/send-webhook.sh /send-webhook.sh
COPY build/startup.sh /startup.sh
COPY build/debug-gc.sh /debug-gc.sh

RUN chmod 0755 /usr/bin/docker-gc \
  && chmod 0755 /generate-crontab.sh \
  && chmod 0755 /executed-by-cron.sh \
  && chmod 0755 /send-webhook.sh \
  && chmod 0755 /startup.sh \
  && chmod 0755 /debug-gc.sh \
  && chmod 0644 /etc/docker-gc-exclude

CMD /startup.sh

