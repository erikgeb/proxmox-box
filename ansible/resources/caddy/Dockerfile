# Custom Caddy image with the OVH DNS provider compiled in.
#
# The stock `caddy` image ships no DNS plugins, but ACME DNS-01 (the only
# challenge type available on this LAN-only box — no inbound HTTP) needs one.
# We build Caddy with `caddy-dns/ovh` via the official builder stage. Rebuild
# (`docker compose up -d --build caddy`) to pick up Caddy/module updates.
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/ovh

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
