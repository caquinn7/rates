ARG GLEAM_VERSION=v1.19.2

FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine AS builder

# Install Node.js and npm
RUN apk add --no-cache nodejs npm git

# Add project code
COPY ./shared /build/shared
COPY ./client /build/client
COPY ./server /build/server

# Record lockfiles so dependency downloads and builds cannot silently update them
RUN sha256sum /build/shared/manifest.toml \
    /build/client/manifest.toml \
    /build/server/manifest.toml \
    /build/client/package-lock.json \
    > /tmp/lockfiles.sha256

# Install Node.js dependencies for the client
RUN cd /build/client \
    && npm ci

# Compile the client code
RUN cd /build/client \
    && gleam run -m lustre/dev build --minify --outdir=../server/priv/static

# Compile the server code
RUN cd /build/server \
    && gleam export erlang-shipment

# Fail if any dependency lockfile changed during the build
RUN sha256sum -c /tmp/lockfiles.sha256

# Start from a clean slate
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine

# Copy the compiled server code from the builder stage
COPY --from=builder /build/server/build/erlang-shipment /app

# Run the server
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
