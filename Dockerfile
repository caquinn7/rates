ARG GLEAM_VERSION=v1.13.0

FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine AS builder

# Install Node.js and npm
RUN apk add --no-cache nodejs npm git

# Add project code
COPY ./shared /build/shared
COPY ./client /build/client
COPY ./server /build/server

# Install Node.js dependencies for the client
RUN cd /build/client \
    && npm install

# Compile the client code
RUN cd /build/client \
    && gleam run -m lustre/dev build --minify --outdir=../server/priv/static

# Compile the server code
RUN cd /build/server \
    && gleam export erlang-shipment

# Start from a clean slate
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine

# Copy the compiled server code from the builder stage
COPY --from=builder /build/server/build/erlang-shipment /app

# Run the server
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]