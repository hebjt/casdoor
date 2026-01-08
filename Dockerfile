FROM --platform=$BUILDPLATFORM node:22.19.0 AS FRONT
WORKDIR /web

# 1. 启用 Corepack 并强制指定 Yarn 3.6.4 (2026年推荐稳定版)
RUN corepack enable && corepack prepare yarn@3.6.4 --activate

# 2. 禁用 Cypress 二进制下载
ENV CYPRESS_INSTALL_BINARY=0

# 3. 【关键修复】先复制整个 web 目录
# Yarn 3/4 校验严格，必须看到完整的项目结构（包含 craco.config.js 和源码）才能正确匹配 lockfile
COPY ./web .

# 4. 执行安装 (Yarn 3 建议使用 --immutable 确保 lockfile 不变)
# 注意：如果构建报错提示 lockfile 需更新，请在本地运行一次 yarn install
RUN yarn install

# 5. 执行构建 (增加内存限制防止 OOM)
RUN NODE_OPTIONS="--max-old-space-size=4096" yarn run build
# 将构建产物移动到标准目录 build
RUN mv /web/build-temp /web/build


FROM --platform=$BUILDPLATFORM golang:1.25.0 AS BACK
WORKDIR /go/src/casdoor

ENV GOPROXY=https://goproxy.cn,direct
ENV GOSUMDB=sum.golang.google.cn
ENV GOPRIVATE=gitlab.com,github.com
ENV GO111MODULE=on

COPY . .
RUN ./build.sh
# 确保 version_info.txt 生成成功
RUN go test -v -run TestGetVersionInfo ./util/system_test.go ./util/system.go > version_info.txt

FROM alpine:latest AS STANDARD
LABEL MAINTAINER="https://casdoor.org/"
ARG USER=casdoor
ARG TARGETOS
ARG TARGETARCH
ENV BUILDX_ARCH="${TARGETOS:-linux}_${TARGETARCH:-amd64}"

# 2026年 Alpine 镜像优化建议：直接使用 apk add
RUN apk add --no-cache sudo tzdata curl ca-certificates && update-ca-certificates

RUN adduser -D $USER -u 1000 \
    && echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER \
    && chmod 0440 /etc/sudoers.d/$USER \
    && mkdir logs \
    && chown -R $USER:$USER logs

USER 1000
WORKDIR /
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/server_${BUILDX_ARCH} ./server
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/swagger ./swagger
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/conf/app.conf ./conf/app.conf
COPY --from=BACK --chown=$USER:$USER /go/src/casdoor/version_info.txt ./go/src/casdoor/version_info.txt
COPY --from=FRONT --chown=$USER:$USER /web/build ./web/build

ENTRYPOINT ["/server"]


FROM debian:latest AS db
RUN apt update && \
    apt install -y mariadb-server mariadb-client && \
    rm -rf /var/lib/apt/lists/*


FROM db AS ALLINONE
LABEL MAINTAINER="https://casdoor.org/"
ARG TARGETOS
ARG TARGETARCH
ENV BUILDX_ARCH="${TARGETOS:-linux}_${TARGETARCH:-amd64}"

RUN apt update && apt install -y ca-certificates && update-ca-certificates

WORKDIR /
COPY --from=BACK /go/src/casdoor/server_${BUILDX_ARCH} ./server
COPY --from=BACK /go/src/casdoor/swagger ./swagger
COPY --from=BACK /go/src/casdoor/docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=BACK /go/src/casdoor/conf/app.conf ./conf/app.conf
COPY --from=BACK /go/src/casdoor/version_info.txt ./go/src/casdoor/version_info.txt
COPY --from=FRONT /web/build ./web/build

ENTRYPOINT ["/bin/bash"]
CMD ["/docker-entrypoint.sh"]
