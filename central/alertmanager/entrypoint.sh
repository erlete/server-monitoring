#!/bin/sh
set -eu

# POSIX-only template rendering — replace ${VAR} placeholders.
sed \
  -e "s|\${ALERT_TO}|$ALERT_TO|g" \
  -e "s|\${SMTP_FROM}|$SMTP_FROM|g" \
  -e "s|\${SMTP_HOST}|$SMTP_HOST|g" \
  -e "s|\${SMTP_PORT}|$SMTP_PORT|g" \
  -e "s|\${SMTP_USERNAME}|$SMTP_USERNAME|g" \
  -e "s|\${SMTP_PASSWORD}|$SMTP_PASSWORD|g" \
  -e "s|\${SMTP_REQUIRE_TLS}|${SMTP_REQUIRE_TLS:-true}|g" \
  /etc/alertmanager/alertmanager.yml.tmpl \
  > /tmp/alertmanager.yml

exec /bin/alertmanager \
  --config.file=/tmp/alertmanager.yml \
  --storage.path=/alertmanager \
  "$@"
