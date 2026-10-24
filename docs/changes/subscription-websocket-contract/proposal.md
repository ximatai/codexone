# 订阅WS请求契约纠正

本轮真实WSS首笔预检在reader关联处失败，原诊断不足，账本unknown/failed且没有可信usage；不能补写唯一根因或零消耗。用户测试Key保持暂停，旧服务不变。先补固定诊断，再修正已有外部依据确认的组包差异，不直接重复真实生成。

固定[官方Codex common.rs](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/common.rs)的ResponsesApiRequest→ResponseCreateWsRequest转换保留stream；[WS序列化测试](https://github.com/openai/codex/blob/1c0c45bfc372fb7d7d581508fdef5eef8235eab7/codex-rs/codex-api/src/endpoint/responses_websocket.rs)以原API请求加type/previous/generate构造预期，没有移除stream。此前把公开Responses WS的隐式stream规则等同订阅后端，独立参数脚本也用了同一错误预期。

按P08—P11/P13—P15与[后端契约](../../specs/protocol.md)，普通订阅WS保留preparedDocument的stream=true/store=false；通用responses WS仍移除stream，图片维持独立契约。由可信配置决定，客户端不能选择。预热和流式压缩属于同一普通订阅WS组包；不扩大工具/图片/续接权限，不改变schema、usage/unknown、重放或健康策略。

验收：独立socket实际捕获两类后端的HTTP/WS wire，分别检查stream形状；reader固定分类在JSON/SSE/native透出UUID而不公开reason/原错误。保持参数拒绝零attempt/零握手、普通输出256项及旧WS/压缩回归；完成两平台验证。真实失败责任继续保留；任何后续实际请求逐笔记录，先定位、首错停，不以fixture替代Desktop。
