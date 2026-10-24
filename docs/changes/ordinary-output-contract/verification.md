# 验证

本轮只记录完成的命令、平台及证据边界；未运行项不计通过。无部署和新增真实订阅调用。

2026-10-24，macOS arm64：`swift build -j 4`通过；`verify_output_views.py`通过HTTP 79次、WS上游153次（含桥接/native），`verify_request_parameters.py`通过314次操作。前者核对多视图、两轮、失败分类、精确派发、绑定和usage/unknown；后者实际捕获wire并验证支持字段、适配及拒绝零attempt。既有`verify_text_contract.py`201次和upstream_events、protocol、websocket通过。均使用loopback无凭证上游，不代表Desktop或模型实测。

主Agent自查：新状态在单次执行栈内有界释放，跨视图验证位于新绑定/提交之前；可信usage屏障及WS reader提前证据保留。订阅参数在gateway准入之前验证，HTTP桥接不能绕过HTTP续接限制；图片/独立compact沿原契约。账号池合成fixture改为实际检查普通HTTP的stream/store/array输入，刷新/禁用的固定身份断言改走独立compact，native续接原测试保留。完整Swift回归、集中review及两平台出口仍待完成。

集中review发现并修复两项：账号池native首轮绕过execute路径，故将请求契约校验前移到首轮准入/上游握手前；新增真实socket检查8种首轮拒绝零attempt/零upgrade/create及成功后的拒绝零增量，通过。透明事件的新call_id原未即时检查重复，已在绑定/转发前检查；独立稀疏重复调用负例通过，HTTP拒绝invalid_upstream_output、WS reader更早拒绝非法关联，均不绑定冲突ID且保留unknown。普通文本/推理摘要完整part生命周期正向通过。参数314次重跑通过，新增每次拒绝的零upstream upgrade断言。review修复后完整出口待运行。
