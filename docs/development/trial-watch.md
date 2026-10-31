# 试运行跟踪程序

`scripts/trial_watch.py` 用 Python 3 标准库做高频巡检，Agent 低频读摘要判断；不调用生成接口。管理认证遵循 [A10/A13](../specs/control-plane.md)，就绪及回退边界遵循 [O12/O13](../specs/operations.md)。程序不修改 Nginx 配置，不恢复数据库或旧余额。

## 私有配置

配置和状态放在仓库外，配置文件建议权限 0600、目录 0700。下面全部使用占位符，替换后才可运行：

```json
{
  "transport": ["ssh", "<host>"],
  "remote": {
    "compose_directory": "<absolute-compose-directory>",
    "ready_url": "http://<server-loopback>:<data-port>/health/ready",
    "admin_base_url": "http://<server-loopback>:<admin-port>",
    "admin_token_file": "<absolute-admin-credential-file>",
    "service": "<compose-service>"
  },
  "rollback": "<reviewed-remote-rollback-command>",
  "thresholds": {
    "failure_critical": 0.10,
    "failure_warn": 0.05,
    "minimum_admitted": 20,
    "longest_seconds": 7200,
    "quota_percent": 95,
    "ready_failures": 3,
    "container_failures": 3,
    "probe_timeout": 90
  }
}
```

`transport` 是 argv，程序追加一个命令参数；需接受 stdin，支持例如 SSH 或本地 `sh -c`。远端需 Python 3、Docker Compose、读取指定管理员文件及容器状态/日志的权限。固定 Python 探测脚本与配置经 stdin 送给 `python3 -` 执行；凭证只在远端读入内存，作为独立 Bearer 使用，禁止重定向、不使用环境代理，不向 transport 输出凭证。`rollback` 原样作为最后一个命令参数执行，不自行拼反代路径。建议回滚命令本身也幂等，并检查配置后再 reload。`probe_timeout` 是整次探测/回滚的秒数限制，HTTP 单次上限 8 秒、Docker 子命令 15 秒；大账号池应提高整次期限。

管理及就绪 URL 只接受远端 loopback（localhost 或回环 IP），禁止凭证、查询参数及重定向。阈值省略使用上述默认值；无效或非正值拒绝执行。比例失败率单位为 0..1，额度单位为百分数。进行中时长严格超过阈值才告警，额度及失败率达到阈值即告警。失败率达到 10% 且本区间准入至少 20 次为 critical；5% 为 warn。账号 requires_auth/auth_uncertain 为 critical；新协议、重启增加、critical 日志、额度 95% 为 warn。attention 项沿用其严重度。

## 推荐操作

先检查私有回滚命令和连接权限，再开始切换。切换授权与执行独立于本工具。

```sh
python3 scripts/trial_watch.py check --config '<private-config>' --state '<private-state-directory>'
nohup python3 scripts/trial_watch.py loop --config '<private-config>' --state '<private-state-directory>' --interval 300 --duration 24 --auto-rollback > '<private-console-file>' 2>&1 &
python3 scripts/trial_watch.py summary --state '<private-state-directory>' --since 6
python3 scripts/trial_watch.py rollback --config '<private-config>' --state '<private-state-directory>' --reason 'manual review'
```

也可用 `--until <unix-seconds>` 替代 `--duration <hours>`。SIGINT/SIGTERM 停止后续调度，当前探测有界结束后退出。一个状态目录只允许一个写进程；手动回滚前停止 loop。Agent 头 6 小时每 30 分钟读一次 summary，之后每 2 小时读一次，至少观察 24 小时。summary 不超过 25 行，退出码 0=ok、1=warn、2=critical/已回滚、3=无数据；按所选时段最严重结论汇总。check 同样使用 0/1/2；操作错误为 3。loop 正常结束为 0，已回滚为 2；其健康结论以 summary 为准。

## 自动回滚和统计边界

只有启用 `--auto-rollback` 才会自动执行。成功探测中，就绪连续失败达到 `ready_failures`（默认 3），或容器连续非 running/缺失达到 `container_failures`（默认 3），触发一次回滚并停止。默认五分钟间隔时，首次失败到第三次约十分钟。transport 非零、超时、输出损坏等为 `probe_failed`，中断上述连续计数，不因本机网络故障自动回滚。管理 API 失败标记 management_unavailable；不妨碍已成功读取的就绪/容器硬故障判断。其他 critical 只提醒人工决策。

回滚前原子写入 `ROLLED_BACK`（UTC 秒、原因、exit_code=null），执行结束更新退出码，超时/启动失败为 -1。已有标记永不再次回滚，loop 直接停止。标记表示已尝试回滚，不保证已切回；退出码非零或 null 必须人工核对。确认重新试运行时由操作者选用新的状态目录。手动回滚同样遵守一次性标记；手动 reason 是操作者提供的私有文本，不应填写秘密。

`history.jsonl` 每次追加紧凑聚合记录；`state.json` 原子保存成功探测时间、基线、协议名称、连续计数。首次检查建立日账本基线，不把切换前历史算进本区间。随后用最近 31 个 UTC 日桶差分统计准入和失败，失败不含客户端取消；迟到结算计入发现区间，可能与同区间准入不是同一批请求。长时间断档超过 31 天、账本替换/统计回退不保证精确差分，须新建状态目录。计数恢复与 history 追加不是跨文件事务，崩溃窗口可能产生一条重复计数；不用于财务核算。

上游统计同时保留明确 `upstream_status` 日志的 401/403/429/5xx 计数及账本 authentication_rejected、rate_limited、upstream_unavailable、upstream_rejected 分类。当前账本不保留精确 HTTP 状态，认证拒绝不能拆分 401/403，unavailable 也不能等同精确 5xx；缺少状态日志不代表没有该状态。日志按成功检查时间至远端采样时刻读取，Docker 时间边界可能重复，日志轮转或进程退出可丢失；仅作诊断统计。容器重启总数增加告警，容器被重建后计数可能重置。

进行中 API 最多 200 条，达到上限时峰值及最长时长可能低估；账号分页有扫描上限，过大池会报告探测失败。账号保留授权状态及所有窗口最大百分比，不保留显示名。`/api/attention` 404 兼容；存在时仅保留 kind、severity、subject（subjectType），不保留 subjectName/ID 或自由文本 detail。管理读取失败不会冒充健康空结果。低盘就绪保护可表现为就绪失败，未来 attention 的 storage_pressure 另列 critical；不另行猜测磁盘阈值。

凭证、请求正文、原始日志、管理 API 原始响应、transport stderr 均不落地、不打印。远端日志只在内存解析；本地仅保存聚合字段及受限协议名称。summary 只读取聚合 history，仍应视为私有运营数据。程序不替代通知系统；后台运行时须安排 Agent/人工按节奏读取。

## 合成验证入口

从仓库根运行（不需要真实账号、SSH、Docker 或 Linux 构建）：

```sh
swift build --disable-sandbox -j 12 --skip-update --product codexone
python3 scripts/verify_trial_watch.py
python3 scripts/check_docs.py
```

测试使用假 transport、本地合成 HTTP，以及现有 verify_admin 的隔离合成网关启动方式；真实执行远端 Python 探测脚本，以假 Docker 命令提供容器状态，验证管理员 Bearer、attention 404/存在、阈值、超时、回滚一次性和秘密不落地。此入口为独立定向组，不加入每次后端全量验证。
