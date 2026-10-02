FROM golang:1.27.1 AS build
WORKDIR /src/coredns
ARG COREDNS_TAG=f44a91377a0bd2ffbbda1cff6745ba46a37e756c
RUN git clone --no-checkout --filter=blob:none https://github.com/coredns/coredns.git . \
 && git checkout "$COREDNS_TAG" \
 && sed -i '/^tls:tls$/a dso:github.com/kentzo/coredns-dso' plugin.cfg
RUN openssl req -x509 -newkey rsa:4096 -sha256 \
    -nodes -days 365 \
    -subj "/CN=home.arpa" \
    -addext "subjectAltName=DNS:home.arpa,DNS:*.home.arpa" \
    -keyout home.arpa.key -out home.arpa.crt \
 && chmod 600 home.arpa.key
ENV GOFLAGS="-buildvcs=false"
COPY . /src/coredns-dso
RUN --mount=type=cache,target=/go/pkg/mod \
 go mod edit -replace github.com/kentzo/coredns-dso=/src/coredns-dso \
 && go get github.com/kentzo/coredns-dso \
 && make gen && make

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /src/coredns/coredns /bin/coredns
COPY --from=build --chown=65532:65532 /src/coredns/home.arpa.key /etc/ssl/private/
COPY --from=build /src/coredns/home.arpa.crt /etc/ssl/certs/
WORKDIR /etc/coredns
COPY <<'EOF' Corefile
dns://home.arpa. {
    errors
    log
    tls /etc/ssl/certs/home.arpa.crt /etc/ssl/private/home.arpa.key
    dso {
        tls_port 853
        log
        push home.arpa.
    }
    file db.home.arpa. {
        reload 0
    }
}
EOF
COPY <<'EOF' db.home.arpa.
$ORIGIN home.arpa.
$TTL 10
@ IN SOA ns nobody.invalid. (22 3600 1200 604800 10)
@ NS ns
ns AAAA 2001:db8::1

_services._dns-sd._udp PTR _smb._tcp
_smb._tcp PTR Media._smb._tcp
smb AAAA 2001:db8::1
Media._smb._tcp SRV 0 0 445 smb
Media._smb._tcp TXT ("path=/media" "u=guest")

dns AAAA 2001:db8::1
_dns-push-tls._tcp SRV 0 0 853 dns
EOF
EXPOSE 53 53/udp 853
ENTRYPOINT ["/bin/coredns"]
