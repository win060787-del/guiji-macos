# 本机服务协议 v1

## 生命周期与权限

默认停止；用户在服务页启动后可用，App 关闭即停止。Socket：`~/Library/Application Support/NovaContextDemo/Service/api.sock`。父目录 0700，socket 0600，只有同用户进程可连接；不监听 TCP。文件锁排除双实例，启动时仅清除本用户的旧 socket。授权配置损坏时拒绝启动或拒绝请求，不清空原数据。

临时授权是 bearer capability，不是可离线解密的密钥。仅存摘要；导出/剪贴板中的临时 Token 仍需保密。项目路径是授权范围标识，不是进程身份认证；持有 Token 的同用户进程可在该范围调用。API Key 不会返回给 Agent。不能撤回已受理的请求或已返回的数据。

## 请求与响应

每个连接仅一行 UTF-8 JSON + 换行，最多 4096 字节，不接受额外字段：

```json
{"version":1,"requestID":"UUID","token":"nva_<random>","project":"/absolute/project/path","operation":"github.identity"}
```

响应为一行 JSON，version=1，回显可解析的 requestID，ok=true 时 result 仅含 login/id/type；失败 error 为固定代码，不回传密钥、请求 Token、原始 API 错误或 URLSession 错误描述。格式不可解析时 requestID 可能为空；客户端将无法关联的响应视为 invalidResponse。

- `invalidRequest`：版本、字段、操作或大小不符。
- `denied`：Token 无效或项目不匹配；坏授权文件亦拒绝访问。
- `expired` / `revoked`：授权到期 / 作废。
- `credentialChanged` / `credentialUnavailable`：凭证变更 / 未关联、已到期或不可用。
- `duplicate`：该授权最近 128 个请求 ID 中重复；失败请求重试也需新 requestID。
- `upstreamFailed`：HTTP、网络、重定向、超限或响应契约失败。
- `busy`：服务停止或同时执行超过 4 个。

Socket 同时最多 8 个连接（最多 4 个处理请求，其余仅容纳响应收尾）；超额连接、超时、非法帧可直接断开，客户端返回 serviceUnavailable。接收超时 3 秒、整体读入约 5 秒，单请求等待最多 20 秒；HTTP 请求/资源超时分别 10/15 秒，响应上限 64 KiB。只对固定 HTTPS GitHub 端点使用 Authorization 头，拒绝重定向，不接收目标 URL、请求体、文件内容或任意参数。

## 状态与恢复

授权记录保存项目、凭证 ID/版本摘要、创建/到期/作废时间、最近使用时间、最近 128 个请求 ID 和最近执行结果，不保存内容、原始 Key 或授权 Token。重新生成一次原子写入同时作废旧授权并创建新授权。过期/作废记录可手动删除；最多保留 1000 条。修改原凭证配置会使旧授权不可用，需要主动重新生成。

## 客户端

`python3 nova-agent.py --grant <0600 授权文件>`。客户端验证文件和 socket 权限、仅用 Unix socket、校验请求关联、限制响应大小。stdout 为结构化结果；不把 Token 放在命令行参数或日志中。需要 Python 3，无第三方库。

## 外部契约来源

- GitHub 用户接口：https://docs.github.com/en/rest/users/users#get-the-authenticated-user
- Apple 通知授权：https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications
