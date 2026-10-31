# 版本与发版规则

定义公开版本、自动发版、产物检查和首次发布的维护者操作。

## 版本与标签

公开版本为 `0.<两位年份>.<序号>`，首个公开版本计划为 `v0.26.1`，尚未发布。序号从 1 起在对应年份递增，不带前导零；年份变化不代表兼容性变化。预发布使用 `v0.26.2-rc.1`，rc 序号同样从 1 起。未来进入大版本 1.x。

每个版本的 CHANGELOG 段落必须以非空“升级注意”开头，说明 schema、配置、客户端兼容性、备份与迁移要求，不能从版本号推断无损升级或回退。Release 正文取该版本段落（不含版本标题），顶部保留“升级注意”，末尾追加镜像 digest、拉取及来源证明核验命令。

发布渠道为 GHCR `ghcr.io/ximatai/codexone`，首个版本发布后可用，仅支持 Linux amd64。每次只推精确版本（如 `0.26.1` 或 `0.26.2-rc.1`），正式版另更新 `latest`；预发布不动 `latest`，不提供 `0.26` 浮动标签。安装使用 digest 或本地不可变 image ID，不能以 `latest` 作为可追溯部署记录。

## 维护者发版步骤

1. 在待合并变更中核对版本、锁文件、兼容性与升级注意，将 CHANGELOG 对应标题的“未发布”替换为发布日期，例如 `## 0.26.1（2026-11-01）`；预发布须有独立的 `0.26.2-rc.1` 段落。扫描分发材料中的凭证和私人数据。
2. 合并到 `main`，确认常规 Verify 和所需平台验收通过。建议先运行一次下述 dry-run，检查产物；模板存在不等于远端验证成功。
3. 在 `main` 历史上的选定提交创建并推送标签，例如 `git tag -a v0.26.1 -m 'Release v0.26.1'`、`git push origin v0.26.1`。不要改写已有发布标签。标签工作流拒绝非法格式、非 main 历史的提交、缺失/重复版本段落或仍标为未发布的标题。
4. 观察 Release 工作流：验证 job 构建 verification target 和携带 SOURCE_REVISION/VERSION 的 runtime，执行本地真实 TLS 反代及实际 Compose 安装验证；验证通过后转交保存的同一镜像，发布 job 登录 GHCR、推送并生成来源证明，最后独立 job 创建 GitHub Release。相同标签串行且不取消在途发布。
5. **维护者首次发布后须在 GHCR 包设置中确认可见性为 Public，并确认关联 `ximatai/codexone` 仓库。** 镜像带 source 标签，但不能由工作流定义推断包可见性或现有包权限；若历史包不允许 GITHUB_TOKEN 写入，须先在包设置授予仓库 Actions 访问。检查未登录客户端能拉取精确版本。
6. 核验附件、镜像和来源证明，再更新 STATUS 的实际可用状态。GitHub Private vulnerability reporting、fork PR 首次贡献者审批及 Actions/包权限设置仍须维护者核对。

## Dry-run

在 Actions → Release → Run workflow 中选择包含该工作流的分支，输入 `ref`（默认 `main`，可为分支、提交或标签）。手动运行始终只构建、执行全部上述验证并上传产物，不登录 registry、不推送镜像、不生成远端来源证明、不创建 Release。未发布 CHANGELOG 标题在 dry-run 中允许；分支/提交使用 CHANGELOG 首个版本，标签仍须格式合法且在 main 历史上。

替代原手动 Linux candidate 工作流。固定 v8 revision 的 peer 构建、旧二进制专项迁移/拒绝检查与 peer 分发只服务当次 schema 迁移，不适合作为每版依赖，因此从通用发版流程移除；不改变 v10 的回退约束。`verify_installation.py` 的 `--incompatible-image` / `--previous-image` 原本已可选，继续保留给有实际旧产物的定向演练。通用流程仍执行 verification target 的迁移/切回失败检查，以及真实安装的 v5 合成旧库拒绝、备份迁移、锁、持久化和重启检查；这些不等同于真实旧二进制兼容验收。

本地政策检查不需要 Docker 或网络：

```sh
python3 scripts/test_prepare_release.py
python3 scripts/prepare_release.py --dry-run --output-dir artifacts/release-policy
python3 scripts/check_docs.py
```

## 产物与核验

验证 job 上传 `verified-release-files` 与 `verified-linux-amd64-image`，保留 7 天；后者包含可用 `docker load --input codexone-linux-amd64.tar.gz` 导入的镜像。tag 发布成功后上传 `published-release-files`，保留 30 天，并把以下文件附到 Release：

- 带版本前缀的源码归档、镜像内二进制的 SHA-256（二进制依赖镜像内 Swift 运行时，不单独提供下载）、实际镜像 `/opt/codexone/licenses` 和项目 LICENSE/清单打包的 `licenses.tar.gz`。
- `image-id.txt`、`image-digest.txt`、`source-revision.txt`、`binary-sha256.txt`、`release.json` 与 `release-notes.md`。
- `SHA256SUMS` 覆盖上述文件及 `image-archive-sha256.txt`，后者核对工作流单独保存的镜像归档。Release 不附巨型 Docker 镜像归档；`sha256sum --check SHA256SUMS` 只需 Release 的全部附件。

Dry-run 的 `image-digest.txt` 明确记录未发布和本地 image ID；它不是 registry manifest digest。正式发布后替换为推送结果的 digest，再重新计算校验和。验证后二进制摘要须与 verification/TLS 所用二进制一致；镜像归档在跨 job 转交时校验，加载后核对 image ID，按 digest 从 registry 拉回后再次核对同一 ID。不重新构建发布镜像。

```sh
# 在下载全部 Release 附件的目录执行
sha256sum --check SHA256SUMS
sha256sum --check binary-sha256.txt
# 将版本替换为要核验的精确版本；不使用 latest 作为记录
ver=0.26.1
gh attestation verify "oci://ghcr.io/ximatai/codexone:$ver" -R ximatai/codexone
docker pull "ghcr.io/ximatai/codexone@$(cat image-digest.txt)"
docker image inspect "ghcr.io/ximatai/codexone@$(cat image-digest.txt)" --format '{{.Id}}'
cat image-id.txt
```

来源证明绑定 registry digest、源码与工作流身份（`gh attestation verify oci://ghcr.io/ximatai/codexone:<ver> -R ximatai/codexone`）；SHA256SUMS 用于完整性，不能独立证明来源。下载附件仍须来自受信 Release。镜像有来源证明不表示真实订阅、Desktop、弱服务器容量或部署环境已验收。

发布权限按 job 隔离：验证只有 contents read；镜像发布只有 contents read、packages write、id-token write、attestations write；创建 Release 的 job 才有 contents write。推送、证明、latest 更新或建 Release 失败可能留下部分远端产物；先检查失败日志和已发布 digest，再重跑失败 job。已有 Release 时 `gh release create` 会拒绝，不自动覆盖附件或改写标签。不同版本并行完成时 latest 指向最后成功执行更新的正式版，维护者应顺序发布正式版。

发布前须核验[第三方许可](../../THIRD_PARTY_NOTICES.md)，保留 Swift、npm、系统库的 LICENSE/NOTICE/COPYING；独立二进制或 SPA 分发也须附适用许可。前端包版本仍是内部开发占位值，不表示已有公开版本。仅实际发布成功才更新公开可用状态。

## 相关文档

[CHANGELOG](../../CHANGELOG.md) · [构建验证](verification.md) · [安装升级](../guide/backup-upgrade.md) · [安全政策](../../SECURITY.md)
