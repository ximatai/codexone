# 验证

本轮只记录完成的命令、平台及证据边界；未运行项不计通过。无部署和新增真实订阅调用。

2026-10-24，macOS arm64：`swift build -j 4`通过；`verify_output_views.py`通过HTTP 79次、WS上游153次（含桥接/native），`verify_request_parameters.py`通过314次操作。前者核对多视图、两轮、失败分类、精确派发、绑定和usage/unknown；后者实际捕获wire并验证支持字段、适配及拒绝零attempt。既有`verify_text_contract.py`201次和upstream_events、protocol、websocket通过。均使用loopback无凭证上游，不代表Desktop或模型实测。

主Agent自查：新状态在单次执行栈内有界释放，跨视图验证位于新绑定/提交之前；可信usage屏障及WS reader提前证据保留。订阅参数在gateway准入之前验证，HTTP桥接不能绕过HTTP续接限制；图片/独立compact沿原契约。账号池合成fixture改为实际检查普通HTTP的stream/store/array输入，刷新/禁用的固定身份断言改走独立compact，native续接原测试保留。完整Swift回归、集中review及两平台出口仍待完成。
