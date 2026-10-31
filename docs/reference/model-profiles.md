# 受信模型profile与长执行配置

导入已审核的离线模型能力，并配置有界执行期限。

`CODEXONE_IDENTITY_CONFIG` / `CODEXONE_ACCOUNT_POOL_CONFIG` 均可声明 `modelProfilesFile`。它是管理员已审核的离线文件，不进行联网发现、提供者登录或读取个人客户端配置。安装Compose可将文件放在既有私有secrets目录，容器路径例如 `/run/codexone/model-profiles.json`；不要在公开配置提交真实指导、路径或账号资料。

快照为当前用户所有的0600普通文件（拒绝链接），最大4MiB。示例使用合成信息：

```json
{
  "version": 1,
  "source": "operator-approved",
  "revision": "synthetic-v1",
  "capturedAtUnixSeconds": 1,
  "clientVersions": ["0.163.0"],
  "models": [{
    "id": "synthetic-text",
    "upstream": {
      "slug": "synthetic-text",
      "base_instructions": "Synthetic guidance",
      "input_modalities": ["text", "image"],
      "prefer_websockets": true,
      "unknown_member": {"nested": true}
    }
  }]
}
```

source/revision/clientVersions是1—64字符的ASCII标签（字母、数字、点、下划线、横线），不得填私有URL/路径；客户端清单最多8个且不重复。采集时间必须有效且不得超前超过60秒；超过30天在目录标陈旧，不据此伪造更新或自动启停模型。版本1的快照封装只接受已定义字段（upstream 内未知成员保留），整份快照模型最多32个且唯一，即使未选用的条目也必须通过指导/字段校验。

只有部署models已明确选择的模型会导入profile；缺对应模型拒绝新启动，不新增路由、价格、视觉/生成权限或宿主映射。可显式提供内联catalog作**整体覆盖**，须有完整非空baseInstructions，不把指导和其他字段逐项混合；有效元数据及来源摘要参与策略版本，价格版本保持独立。contextWindow与maxContextWindow分别表达默认与最大上下文（最大2000000），不扩大网络正文、输入项和本地容量限制；提供者声明也不证明真实能力。

`upstream` 必须为 JSON 对象，含非空字符串 `base_instructions`；`slug` 若存在须等于条目 id。每个 upstream 序列化后最多256 KiB。它与旧 `catalog` 互斥；catalog 保留为兼容合成路径（baseInstructions 最多32 KiB）。内联 catalog 整体覆盖 upstream 后也使用旧合成路径。upstream 的任意未知嵌套成员保留；输出仅覆盖 slug、priority，无视觉权限时移除 input_modalities 中的 image，未启用原生 websocket 时设置 prefer_websockets=false，并附加来源信息。内容和快照哈希进入策略版本，计价版本不变。

离线导入管理员已保存的提供者目录（对象含 models 数组，每项有唯一 slug）：

```sh
python3 scripts/import_model_profiles.py --source provider-catalog.json \
  --model synthetic-text --source-label operator-approved --revision synthetic-v1 \
  --client-version 0.163.0 --output new-model-profiles.json
```

--model 可重复，按指定顺序选择；--client-version 可重复。缺模型、重复模型或无效指导失败；输出独占创建为0600，拒绝已有文件和链接，不联网，不读取个人客户端配置，终端只打印模型计数。

GET `/v1/models?client_version=...`（亦支持原前缀）的Codex条目返回codexone_profile：来源标签、revision、原文件字节SHA-256、采集时间、客户端清单、overridden/stale。不是签名或官方认可声明。目录指导会替换客户端基础指导，须针对模型/版本审核；客户端版本清单是管理员声明，不会绕过兼容验证。

启动时把已验证文件加载为内存快照。运行中源文件失效不改已加载实例；新启动遇错误拒绝，原文件不会被程序覆盖。更新时先保留原文件/摘要，在新私有文件核对 `--check-config` 后按停服/启动流程替换；不从无效新文件静默生成指导或回退另一模型。需要回退时恢复明确的旧文件和配置，不恢复旧执行库或释放未知责任。旧候选不识别新增profile/阶段期限配置；回退二进制时还须恢复该版本已验证的兼容配置，保留原快照与密钥依赖，不把新配置直接交给旧版本。

执行配置保留少量参数：executionTimeoutSeconds默认600秒/最大1800，firstResponseTimeoutSeconds默认30秒/最大120，progressTimeoutSeconds默认60秒/最大300；显式阶段值不超过总期限，缺省按总期限取小值。GET模型目录同时给出codexone_execution_budget的有效秒数和default/configuration来源；不回显秘密或路径。WS读下一请求的空闲时钟在有执行或排队turn时暂停，执行/队列有界与一小时连接寿命保持。长任务仍占执行/未知容量，超时不自动重试、切账号或退款。

验证入口：`python3 scripts/verify_client.py --binary <binary> --profile-snapshot`（另支持bridge/websocket），`python3 scripts/verify_long_tasks.py --binary <binary> --duration 125 --output <new-report>`。3秒只作排错，不称超过120秒单次验收。前者使用私有合成快照和独立CLI目录；不操作真实Desktop或订阅。

Linux验证容器若禁止bubblewrap创建用户命名空间，CLI工具执行会先失败，不能计为协议通过。`verify_client.py --outer-container-sandbox`仅供明确隔离的Linux合成测试容器：非root、只读根、network none、临时HOME/CODEX_HOME与资源上限，不挂个人资料或真实凭证。该选项令CLI依赖外层容器而不用内层沙箱，报告明确标记sandbox=outer-container；默认仍为read-only，Linux容器外拒绝该选项。这不改变服务权限，也不证明内层Linux沙箱可用。

## 相关文档

[文档导航](../README.md)
