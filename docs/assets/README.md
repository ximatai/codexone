# 文档截图

通过现有 Playwright 合成 API fixture 展示大屏管理界面。

## 生成

在已安装锁定前端依赖和本机 Chrome 的环境执行：

```sh
npm --prefix web run test:e2e:chrome -- docs-screenshots.spec.ts
```

测试复用 `reviewFixture`、`reportFixture`，固定合成时间，只允许本机测试 origin，其余请求拦截。账号、模型、请求与统计均为合成数据，不访问上游、不读取个人浏览器状态；不打开秘密或授权控件。使用 1440×1000 视口，概览保存全页 PNG，Key 页保存视口 PNG，公开前目视检查、无损压缩并保持单张不超过 400 KB。

## 相关文档

[中文首页](../../README.md) · [来源说明](../reference/provenance.md)
