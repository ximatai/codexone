# 容量演练验证 · 2026-10-22

## 环境与入口

主 Agent 使用 macOS arm64 / Python 3.9 驱动 Docker Linux amd64 实际优化运行镜像；容器内 Python 3.12 合成提供者和压测器独立 cgroup。Engine 为 aarch64、2 CPU、3044167680 字节共享 VM，amd64 有仿真成本；不是约1.6 GiB参考宿主。网关1 CPU/768 MiB/128 PID、swap上限0、非 root/只读/本次私有 Linux 本地卷；压测器1 CPU/512 MiB。网络仅隔离 loopback，不挂 Docker socket。

```sh
python3 scripts/verify_capacity.py --image codexone:v8-candidate \
  --duration 600 --transport both --output artifacts/capacity-600
```

运行镜像 `sha256:0f7e975e11580a8d7466f977d32956534d0e32efd3b99908de49321180bd002b`，源码 `890bf2c9c54f8615c6541a129cabece8c6745610`；运行二进制 SHA-256 `3f04ccf776657b247009e678213d28ca179ed0d95ee8ea9f1d97b3df94504ac8`，沿用候选阶段实际导出/对比证据。持续样本脚本提交 `5679307`。原始报告在忽略的本机产物目录，未推送/发布。

## 夹具修正与失败记录

短程定位修正：空卷初始化 chown 后 chmod 需要 FOWNER；HTTP 上游不开放下游 WS；漏报 cached_tokens 会按真实语义产生 partial/unknown，因此提供者明确报0；compaction opaque 每次唯一；大图片上行 WS 提供者接收上限独立有界到8 MiB。均未放宽产品准入/未知责任或限额。

双配置10秒短程通过后，发现压测器在 pending 为空时 wait(empty) 忙转；首次持续尝试约两分钟后主动中止，独占容器/卷已清理，不计通过。修复有界休眠并增加 CPU 计数后，重新从空卷运行本次持续样本；没有把中止片段拼接为600秒。24路超载由总连接上限8触发协议前关闭，其余连接失败不能当成 HTTP 429。

## 限制

仅多 Key、名义4请求/秒、最多4在途、每配置600秒、单张约3 MiB有效PNG的当前合成包络；不测缓存，不扩大产品承诺。HTTP keepalive、长寿命多turn、全部最大图片/帧/工具组合、Swift async task tracing、真实提供者与实际旧服务混合负载、目标宿主均保留。线程为Linux线程数，FD/队列为周期采样，cgroup峰值含文件页缓存与采样helper；回稳不等于证明长期无泄漏。O14、Desktop、真实订阅及M5不标完成。

## 持续样本结果

两配置各600秒完整通过，报告 `artifacts/capacity-600/report.json`；运行脚本 `5679307` 保持不变。开始/结束均有3个共存容器，未触碰它们；本次容器和卷已清理。

| 指标 | HTTP上游 | 原生WS上游 |
|---|---:|---:|
| 持续提交 / 跳过时隙 | 2335 / 30 | 2267 / 19 |
| 实际完成请求/秒（含收尾） | 3.891 | 3.775 |
| 正常调用（含覆盖） | 2340，全部200 | 2274，全部200 |
| 提供者调用 / settled / unknown | 2350 / 2348 / 2 | 2284 / 2282 / 2 |
| 采样RSS峰值 / 回稳 MiB | 145.1 / 74.4 | 143.9 / 75.8 |
| cgroup历史峰值 MiB | 202.5 | 210.9 |
| FD基线 / 峰值 / 回稳 | 27 / 43 / 27 | 27 / 43 / 27 |
| 线程采样峰值 | 10 | 10 |
| writer普通/关键排队峰值 | 4 / 1 | 2 / 1 |
| 最大writer等待 ms | 506.3 | 242.6 |
| WAL采样峰值 KiB / 回稳 | 567.3 / 0 | 458.7 / 0 |
| 图片生成/编辑 p95 秒 | 0.322 / 0.837 | 0.533 / 1.282 |

每组24路超载为8路完成、16路连接级关闭，约2.1秒内全部收敛；无提供者重放、无intent，汇总恰有2个unknown/2单位未知预留；初版报告未关联断流Key，不能从汇总证明逐请求归属。WS上游故意截断事件触发约10秒执行期限后保留unknown，不能声称上游立即停止。核心/pressure正常，最终writer队列/WAL归零，cgroup OOM计数0、swap上限0，运行进程正常停止exit0。RSS基线约57 MiB，回稳仍比冷启动高约18 MiB；没有以低于预算冒充完全回到冷启动或长期无泄漏。

cgroup累计CPU约296.2/309.1秒，throttle累计约61.5/69.2秒；受1 CPU配额和amd64仿真影响，未达到固定4RPS应如实保留，不给原生硬件性能承诺。

## 集中 review 修复

主 Agent 提交 `5679307`/`3bc6428` 后，两名只读review集中提出三项P2：首次volume create超时缺清理owner、无标签root initializer无法回收；旧成功DTO可冒充回稳；unknown汇总未关联断流归属。主 Agent修复：首次Engine写前建立owner、初始化标签/资源限制；要求 baseline/sustained/recovery及至少两个5秒内回稳DTO；断流使用独立Key/主体，逐主体核对unknown/预留/无完整证据，其余派发项settled。初版长样本仅保留其实际汇总/性能证据，不补造归属。

`python3 scripts/verify_capacity_guards.py --image codexone:v8-candidate --report artifacts/capacity-600/report.json`：两份真实长样本有实际recovery证据；删除回稳样本、时间陈旧、关键队列未清空均拒绝；真实Engine创建成功后注入volume CLI超时和仍运行initializer结果丢失，本次容器/卷全部回收。失败路径通过，不需重跑未改工作负载的600秒测量。

修复后 `--duration 10 --transport both --output artifacts/capacity-review-regression` 完整通过：两配置的独立断流主体各恰有2个unknown/2单位预留/0完整证据，其他四主体派发项全settled；最新回稳DTO/队列/FD、无OOM/swap、正常停止和秘密日志检查通过。该短程是责任/失败保护回归，不替代600秒容量时长。

两名subagent只读复审确认三项P2关闭，无新增发现。跨平台范围为macOS宿主驱动与实际Linux amd64候选/worker，架构检查通过；Swift/前端业务源码未改，沿用上一阶段175项Swift及前端完整/实际UI证据，不重复全集。文档检查、Python语法与提交隐私检查通过；无真实调用/推送/部署，阶段资源已清理。完整O14未完成。
