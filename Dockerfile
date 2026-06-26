FROM alpine:3.19 AS builder
RUN apk add --no-cache build-base git
RUN git clone --depth=1 https://github.com/rofl0r/microsocks.git /tmp/microsocks
RUN cd /tmp/microsocks && make

FROM alpine:3.19
RUN apk add --no-cache openvpn curl bash fping haproxy tinyproxy
COPY --from=builder /tmp/microsocks/microsocks /usr/local/bin/microsocks
COPY vpngate2socks.sh /
RUN chmod +x /vpngate2socks.sh
ENTRYPOINT ["/vpngate2socks.sh"]
