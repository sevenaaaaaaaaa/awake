# Awake 接力协议（v1，手机 → 电脑）

目标：手机正在播放时，把曲目与进度交给同一局域网内的电脑继续播放。不走云端、不保存用户凭据。

## 电脑端接收器

- 用户点击「接收接力」后启动：
  - HTTP 服务监听 `0.0.0.0` 的临时端口，只接受局域网请求；
  - 通过 mDNS 发布 `_awake._tcp.local.`，TXT 含 v=1、name=<主机名>、code_required=1；
  - 生成 6 位数字配对码，显示在界面；会话 10 分钟无请求自动过期；服务停止即失效。
- 每 2 秒最多处理 1 个请求；配对码错误最多 5 次，超过则换新码并返回 429；请求体上限 8 KB。
- 只接受 `POST /handoff`；其他路径 404；只处理 JSON。
- 请求体：

```json
{
  "code": "123456",
  "track": { "title": "曲名", "artist": "艺人", "album": "专辑", "duration": 225.0 },
  "position": 42.5,
  "playing": true
}
```

- 响应：
  - 200 `{"ok":true,"matched":true,"title":"...","message":"已开始播放"}`
  - 200 `{"ok":false,"matched":false,"error":"电脑曲库没有找到这首歌"}`（未匹配）
  - 401 配对码错误；429 尝试过多；400 请求格式错误。
- 匹配规则：曲名/艺人/专辑归一化（大小写、括号、feat、标点）+ bigram 相似度，时长 ±5s；优先本地文件存在的曲目；阈值 ≥0.62。
- 匹配成功后：用电脑端当前音量/EQ 播放该曲目，并 seek 到 position；向前端 emit `handoff://received` 事件（payload: title, position, matched）。
- 失败信息不包含路径、账号或网络细节。会话停止后释放端口与 mDNS 注册。

## 手机端发送者

- 入口：正在播放页「接力到电脑」；仅当有当前曲目时可用。
- 发现：NetServiceBrowser 浏览 `_awake._tcp`，列出设备名；解析 host/port；展示配对码输入框；提供“手动输入 IP:端口”兜底。
- 发送：`POST http://<host>:<port>/handoff`，JSON 如上，超时 5 秒；成功后提示“已接力到 <设备>”，失败给出可读原因（配对码错误/未找到歌曲/网络）。
- 不在手机上保存配对码；不发送音频文件、账号或 token。

## iOS Info.plist

- `NSBonjourServices` 包含 `_awake._tcp`
- `NSLocalNetworkUsageDescription` 已有（连接 NAS/WebDAV/Plex/连接器），补充“接力播放”说明。

## 安全边界

- 仅局域网；配对码是唯一的授权凭据；不提供公网监听、不做端口转发。
- 请求体只含曲目元数据与进度；不含文件路径、凭据、设备标识。
- 用户可随时停止接收；停止后端口关闭、mDNS 注销。
