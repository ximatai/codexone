# 管理页面静态资源交付

对符合前端构建命名约定的 JS/CSS 启用浏览器长期缓存。HTML 保持每次读取最新的资源地址，旧版和自定义无哈希资源继续使用原有缓存策略。HTTPS 反代只在管理静态资源位置启用 gzip。

涉及 [A11 管理页面](../../reference/specs/control-plane.md#a11同源管理会话与静态界面)和[TLS 反代](../../operations/tls-proxy.md)。验收核对入口、版本化资源、普通资源、缺失资源和管理 API 的响应头，确认 gzip 仅应用于静态资源。无数据库迁移，旧镜像和原反代片段可直接恢复。

## 相关文档

[任务](tasks.md) · [验证约定](../../development/verification.md)
