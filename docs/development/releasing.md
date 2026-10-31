# 版本与发版规则

定义公开版本、兼容性说明和产物检查要求。

## 版本与标签

公开版本为 `0.<两位年份>.<序号>`，首个公开版本计划为 `v0.26.1`，尚未发布。序号在对应年份递增；年份变化不代表兼容性变化。未来进入大版本 1.x。

每个版本发布说明顶部必须有“升级注意”，说明 schema、配置、客户端兼容性、备份与迁移要求，不能从版本号推断无损升级或回退。CHANGELOG 保留用户可观察变化。

发布渠道为 GHCR `ghcr.io/ximatai/codexone`，首个版本发布后可用。镜像仅提供精确版本（如 `0.26.1`）与 `latest`，不提供 `0.26` 浮动标签。安装使用 digest 或本地不可变 image ID，不能以 `latest` 作为可追溯部署记录。

## 当前自动化边界

仓库有常规验证和手动 Linux candidate 工作流。candidate 构建并上传候选归档，不登录 GHCR、不推送镜像、不创建正式 Release。GHCR 发版 CI、发布元信息标签、依赖更新自动化、常规 CI 工具链进一步固定与锁文件约束留待下一阶段。前端包版本仍是内部开发占位值，不表示已有公开版本。

保留完整 Git 历史；candidate 的旧 schema 回退验证仍依赖固定历史提交，不重建公开历史。GitHub Private vulnerability reporting、fork PR 首次贡献者审批与 runner 资源设置需要维护者在仓库设置中核对，无法从当前树确认。

## 发布检查

1. 核对版本、源码 revision、锁文件与 CHANGELOG 的升级注意，扫描当前树及待分发材料中的凭证和私人数据。
2. 按[构建验证](verification.md)运行适用平台的合成测试；独立记录 Linux 镜像、安装、备份恢复、回退及客户端版本范围。没有运行的检查如实列出。
3. 为每个镜像保留源码归档、revision、镜像 digest、实际二进制摘要与校验和。校验和不单独证明来源。
4. 核验[第三方许可](../../THIRD_PARTY_NOTICES.md)：镜像已有收集机制；独立二进制分发附 Swift LICENSE/NOTICE/COPYING、系统库通知与项目 LICENSE，单独 SPA 分发附 npm 运行依赖声明和补充许可。分发构建工具时同时履行其许可，核对 MPL、组合许可与加密库嵌入来源。
5. 只有实际发布成功才更新 STATUS 的版本可用状态。报告支持平台、未验证组合及恢复限制。

## 相关文档

[CHANGELOG](../../CHANGELOG.md) · [安装升级](../guide/backup-upgrade.md) · [安全政策](../../SECURITY.md)
