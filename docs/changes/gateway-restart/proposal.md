# 网关自动重启

拟把安装 Compose 中 gateway 的重启策略从 `"no"` 改为 `unless-stopped`，使宿主机重启或进程意外退出后自动恢复服务，同时保持维护命令不会被自动重试。

## 问题

当前 gateway 与 init-data 都是 `restart: "no"`。dockerd 开启 live-restore 时，Docker 自身重启不影响运行中的容器；但宿主机重启、内核升级或进程意外退出后，gateway 保持停止，直到操作者手动执行 `compose-install.py up`。对个人自托管网关，这一段不可用通常无人值守，与可用性优先的目标不符。

## 依据

自动拉起只有在“重复启动不改变持久状态的含义”时才安全。现有启动路径满足这一点：

- 服务启动不执行迁移。打开数据库只接受当前 schema 或空库，其余以 `incompatibleSchema` 拒绝；迁移、restore 与密钥维护是独立命令，并与服务共用实例锁（O03）。
- 启动恢复（O02）是幂等的保守收敛：未完成 intent 归为 unknown 并核对，未完成刷新归为 `auth_uncertain`，重复执行不会把状态推向更宽松。
- 配置错误以 78 退出，不打开 listener；存储空间不足以 1 退出，空间恢复后再次启动即可接单。
- 运行中的容量拒绝、账号耗尽与 ready 503 不导致进程退出（O08、O12），因此不会因策略改变而形成重启循环。

Docker 对 `unless-stopped` 的连续失败使用递增退避，日志受现有 json-file 轮转（10 MiB × 5）约束；配置错误类循环不会耗尽磁盘或调用提供者。

## 范围

1. `deploy/compose.yaml`：gateway 改为 `restart: unless-stopped`；init-data 保持 `"no"`，宿主机重启后不重新执行（卷已初始化，Docker 只按策略重启 gateway 本身）。
2. 维护命令：`compose-install.py run gateway --migrate` 等一次性容器必须不继承自动重启。如 Compose 的 `run` 不能保证这一点，入口须显式覆盖为不重启，并有验证。
3. 手动停止语义：`compose-install.py stop`/`down` 后不会被 dockerd 或宿主机重启拉起；维护流程仍要求先停止 gateway 再执行维护命令，文档明确这一点。
4. 安装验证 `scripts/verify_installation.py`：断言新策略；在真实 Docker 中覆盖进程被 SIGKILL 后自动恢复且 ready 回到 200、`stop` 后保持停止、一次性维护容器失败后不被重启、配置错误时有界退避且不打开 listener。
5. 文档：Linux 安装指南说明重启策略、宿主机重启后的行为、如何临时禁止自动启动；运维规范 O12 增加重启策略条款；trial watch 已有 `container_restarted` 提醒，说明自动恢复仍会被观测到，不能被当作正常。

## 不做

- 不对 init-data 启用重启，不在服务启动时自动迁移。
- 不新增“停机标记”或自定义 supervisor：启动失败路径本身不改写持久状态，额外机制没有收益。
- 不改变 liveness/readiness 语义，不让 unhealthy 触发重启。
- 不处理 systemd/非 Compose 部署方式。

## 规范影响

- [运维](../../reference/specs/operations.md) O12：安装 Compose 的 gateway 使用 `unless-stopped`，维护命令与 init-data 不自动重试；连续重启必须可观测。
- [Linux 安装](../../guide/linux-installation.md)：重启策略与维护前停止的说明。

## 验收

- 真实 Docker（Linux amd64）中完成范围第 4 项全部场景，记录日期与平台。
- 已安装实例升级：使用新版 compose 执行 `up` 后 `docker inspect` 显示 `unless-stopped`，数据卷与 Key 不变。
- 回退：旧版 compose 重新 `up` 即恢复 `"no"`，不涉及 schema 或数据变化。

## 相关文档

[任务](tasks.md) · [变更约定](../README.md)
