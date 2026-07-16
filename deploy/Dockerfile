# Dockerfile.ecs
# enable BuildKit cache mounts
# syntax=docker/dockerfile:experimental

#####################################
# 1) Builder stage
#####################################
FROM --platform=$BUILDPLATFORM golang:1.25-alpine AS builder
WORKDIR /app

# cache Go module downloads
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# copy source & cache-build binary
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-w -s" -trimpath \
      -o server ./cmd/server/main.go

#####################################
# 2) Typst binary stage
#####################################
FROM ghcr.io/typst/typst:v0.13.1 AS typst

#####################################
# 3) Runtime stage
#####################################
FROM alpine:3.21 AS runtime
WORKDIR /app

RUN apk --no-cache add ca-certificates

# pull in our Go server
COPY --from=builder /app/server /app/server

# pull in typst
COPY --from=typst /bin/typst /usr/local/bin/

# configs & assets
COPY internal/config ./config
COPY assets/fonts ./assets/fonts
COPY assets/typst-templates ./assets/typst-templates
COPY assets/email-templates ./assets/email-templates

RUN chmod +x /app/server

EXPOSE 8080
CMD ["/app/server"]