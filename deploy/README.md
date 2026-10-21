# 发行部署

首发目标 Linux amd64 OCI/Compose，CI 编译。当前没有 Dockerfile/Compose 或可部署镜像；不得直接把实验容器暴露公网。模板需覆盖非 root、data/secret、SSE/WS 反代、健康检查、备份及回退。任何 Ali 操作另需明确授权。
