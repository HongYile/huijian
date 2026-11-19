# 从源码构建回笺服务端（在仓库根目录执行：docker build -f deploy/docker/Dockerfile .）
FROM golang:1.24-bookworm AS build
# 国内服务器可以在 .env 里设置 GOPROXY=https://goproxy.cn,direct 加速依赖下载
ARG GOPROXY=https://proxy.golang.org,direct
ENV GOPROXY=$GOPROXY
WORKDIR /src
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /out/huijian .

FROM debian:bookworm-slim
RUN useradd -r -u 10001 -M -s /usr/sbin/nologin huijian && mkdir /data && chown 10001:10001 /data
COPY --from=build /out/huijian /usr/local/bin/huijian
# 根证书：服务端要主动访问 https（例如转发到 Bark），slim 镜像里没有，从编译镜像里拿
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 10001:10001
ENV HUIJIAN_DATA=/data
VOLUME /data
EXPOSE 8790 8791
ENTRYPOINT ["/usr/local/bin/huijian", "hub"]
