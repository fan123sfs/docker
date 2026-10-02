FROM docker:27-cli

ARG REGCTL_VERSION=v0.8.3
ARG TARGETARCH=amd64

RUN apk add --no-cache ca-certificates curl \
 && curl -fsSL -o /usr/local/bin/regctl \
      "https://github.com/regclient/regclient/releases/download/${REGCTL_VERSION}/regctl-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/regctl \
 && regctl version

COPY relay.sh /usr/local/bin/relay.sh
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/relay.sh /usr/local/bin/entrypoint.sh \
 && chmod +x /usr/local/bin/relay.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
