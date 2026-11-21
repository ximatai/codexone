# 发行与部署模板

提供 Linux amd64 OCI、Compose 初始化和 TLS 反代模板。

安装顺序、私有配置和镜像边界见[安装部署](../docs/guide/linux-installation.md)，升级恢复见[维护指南](../docs/guide/backup-upgrade.md)。GHCR 镜像首个版本发布后可用，Release 工作流的手动 dry-run 只生成验证归档，版本标签触发验证后的 GHCR 推送、来源证明与 GitHub Release；流程见[发版规则](../docs/development/releasing.md)。

WSS 断开沿用最多 10 秒的终态续读；发版 TLS 验证同时检查定向中断及时到达和无终态时的有界关闭，不要求上游在 3 秒内关闭。验收修正不改变网关或 Nginx 模板，已有实例无需配置迁移；具体失败语义和重复验证命令见 [TLS 指南](../docs/operations/tls-proxy.md)。

## Rust 候选镜像

在干净的 checkout 构建 Linux amd64 候选。使用 `CODEXONE_BACKEND=rust` 选择 Rust，未指定时使用 Swift。候选复用同一前端、Ubuntu 24.04 glibc 运行根装配、系统 CA、维护工具、UID/GID 10001 和 liveness 探针。Dockerfile 中的 Rust 编译器和 Ubuntu 基础镜像均锁定 digest，Cargo 依赖来自网关 `Cargo.lock`。Rust HTTP 客户端使用它所锁定的 WebPKI 信任根，系统 CA 供镜像内 `curl` 等工具使用。

```sh
revision="$(git rev-parse HEAD)"
docker buildx build --platform linux/amd64 --load --provenance=false \
  --build-arg CODEXONE_BACKEND=rust --build-arg SOURCE_REVISION="$revision" \
  --build-arg VERSION=0.0.0-dev -f deploy/Dockerfile -t codexone:rust-candidate .
```

以下检查使用已经加载的候选和 Python 镜像。网关在专用回环网络、只读根、768 MiB 内存和 128 PID 限制下运行；单 CPU 配额用于重复测量。检查镜像元数据、非 root 文件权限、SPA、健康探针、并发 HTTP、SIGTERM、SQLite 结算和离线备份校验。内存来自 Linux cgroup v2，启动时间包含 Docker 启动和主动探测开销。

```sh
harness=python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df
docker pull "$harness"
python3 scripts/rust_compat/release_image.py --image codexone:rust-candidate --harness-image "$harness"
```

计时复用同一构建命令、构建器与参数。可用新建 BuildKit 构建器测冷构建，再原样重跑测热构建，记录基础镜像下载是否计入。脚本另报 `docker save` 归档字节、各层存储字节和解压后的层字节，支持 gzip 或未压缩归档层。候选验收还需原生 Linux 混合容量、完整协议、Compose 安装及双向切换证据。[Rust 兼容工作](../docs/changes/rust-backend/tasks.md)记录进度。

## 相关文档

[版本与发布](../docs/development/releasing.md) · [运维规范](../docs/reference/specs/operations.md)
