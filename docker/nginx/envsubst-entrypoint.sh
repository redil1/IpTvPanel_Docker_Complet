#!/bin/sh
set -e

mkdir -p /etc/nginx/templates
envsubst '$PANEL_DOMAIN' < /etc/nginx/templates/app.conf > /etc/nginx/conf.d/default.conf
exec nginx -g 'daemon off;'
