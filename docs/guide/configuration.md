# 配置网关

配置自己的订阅账号池、模型和本地治理边界。

## 前提

先按[安装部署](linux-installation.md)初始化私有安装目录。所有秘密与运行配置保存在源码目录外，不提交 Git。

## 配置顺序

1. 编辑安装目录的 `secrets/pool.json`，参考 [pool.example.json](../../deploy/pool.example.json)。示例模型是占位符，须换成账号可用、客户端支持的模型。
2. 为对话模型设置视觉输入、托管图片工具能力和输入/输出估算费率。费率单位为每百万 token 的微美元；估算不是提供者账单，也不能换算订阅剩余额度。
3. 需要图片时配置 `imageGeneration` 的默认模型和图片模型列表，并单独授予 Key 图片权限。
4. 需要客户端模型元数据时，使用已审核的[模型 profile](../reference/model-profiles.md)，将文件放在私有 secrets 目录，配置容器内绝对路径。不要把真实模型基础指导提交到仓库。
5. 运行 `python3 compose-install.py run --rm gateway --check-config`。运行中的配置是启动快照，修改后按维护步骤重启。

安装工具生成独立管理员秘密和账号主密钥；二者与下游 Key 不可互换。默认数据/管理端口为 18080/18081，仅监听 loopback。管理公开 origin 必须与浏览器地址完全一致；默认部署使用 HTTPS。无域名时可显式选择[局域网 HTTP](linux-installation.md#局域网无域名)，接受明文风险。

可选出网代理设置 `CODEXONE_UPSTREAM_HTTP_PROXY`，只支持无认证 HTTP CONNECT，失败不直连回退；完整字段和约束见[配置参考](../reference/configuration.md)。

## 相关文档

[管理面板](admin.md) · [账号凭证](../reference/account-credentials.md) · [图片](images.md)
