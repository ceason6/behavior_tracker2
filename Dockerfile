# syntax=docker/dockerfile:1
#
# Production image for the ABC Behavior Tracker: builds the Flutter web bundle
# and compiles the Dart proxy, then ships a tiny runtime image that serves the
# web app AND forwards AI calls to Anthropic. See server/DEPLOY.md.

# ---- Stage 1: build the Flutter web app + compile the proxy ----
FROM ghcr.io/cirruslabs/flutter:stable AS build
# Avoid git "dubious ownership" errors when building as root.
RUN git config --global --add safe.directory '*'
WORKDIR /app

# Cache dependencies first.
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

# Build.
COPY . .
RUN flutter pub get \
 && flutter build web --release \
 && dart compile exe server/proxy.dart -o /app/proxy

# ---- Stage 2: minimal runtime ----
FROM debian:bookworm-slim AS runtime
# ca-certificates is required for the proxy's outbound HTTPS call to Anthropic.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/proxy /app/proxy
COPY --from=build /app/build/web /app/web

ENV WEB_DIR=/app/web
# Hosts (Render, Cloud Run, Fly) inject PORT; the proxy honors it. 8787 is a
# local default.
ENV PORT=8787
# Where the proxy reads the Anthropic key (mount your secret here).
ENV ANTHROPIC_API_KEY_FILE=/etc/secrets/anthropic.key
EXPOSE 8787

CMD ["/app/proxy"]
