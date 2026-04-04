# Minimal runtime image using a pre-compiled binary.
# Build the binary first: just build-linux-amd64
#
# Usage:
#   just docker-image
#   docker run -e WEBHOOK_SECRET=my-token -p 8080:8080 gitlab-webhook-server

ARG BINARY=build/gitlab-webhook-server-linux-amd64

FROM scratch
ARG BINARY
COPY ${BINARY} /gitlab-webhook-server
EXPOSE 8080
ENTRYPOINT ["/gitlab-webhook-server"]
