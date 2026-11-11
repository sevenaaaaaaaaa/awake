# Awake Telegram 个人连接器

由用户在自己的电脑或 NAS 上运行。Awake 桌面版和 iOS 连接这个服务，选择收藏夹或自己已加入的频道中的音频。没有公共频道目录、邀请加入、聊天发送、链接解析或内容保护绕过接口。

当前实现使用 [Telethon 用户 API](https://docs.telethon.dev/en/stable/)，不是 Bot API，也不是在应用内登录完整 Telegram 客户端。验证码和两步验证密码只在运行连接器的终端输入。Awake 客户端只持有连接器的访问令牌。

## 安装与登录

Python 3.9+。在项目根目录执行：

```sh
python3 -m venv Tools/telegram_connector/.venv
Tools/telegram_connector/.venv/bin/pip install -r Tools/telegram_connector/requirements.txt
```

从 [Telegram 开发者页面](https://my.telegram.org/apps) 为自己的应用取得 `api_id` 和 `api_hash`。在运行连接器的终端配置，不要写进播放器的 JSON/XML/TXT 文件：

```sh
export AWAKE_TELEGRAM_API_ID='你的 API ID'
export AWAKE_TELEGRAM_API_HASH='你的 API hash'
Tools/telegram_connector/.venv/bin/python Tools/telegram_connector/connector.py login
Tools/telegram_connector/.venv/bin/python Tools/telegram_connector/connector.py serve
```

默认监听 `127.0.0.1:8765`。另一个终端执行以下命令查看访问令牌，复制到 Awake 的“连接器访问令牌”字段：

```sh
Tools/telegram_connector/.venv/bin/python Tools/telegram_connector/connector.py token
```

`~/.awake-telegram/` 保存 Telegram 会话、访问令牌和媒体库范围，目录权限为 `0700`，新文件权限为 `0600`。**登录会话具有 Telegram 账号访问能力，不能分享、提交到仓库或放进同步配置。** HTTP 接口不接受验证码或 Telegram 密码；没有托管在 Awake 服务端的账号。

## 连接两端

桌面版：音乐来源 → 添加 → Telegram 个人媒体库 → 连接器地址及令牌 → 读取频道与聊天文件夹 → 勾选 → 使用所选来源 → 连接曲库。

iOS：设置 → 添加 WebDAV / Plex / Telegram → Telegram 个人媒体库，后续相同。iPhone 上的 `127.0.0.1` 指 iPhone 自己；连接电脑或 NAS 时须填写该设备地址。局域网部署示例：

```sh
Tools/telegram_connector/.venv/bin/python Tools/telegram_connector/connector.py serve --host 0.0.0.0
```

监听所有接口仅供自己受信任的网络使用。远程访问使用自己配置的 HTTPS 反向代理或私有网络；应用拒绝公共 HTTP 地址。连接器会收到访问令牌，只有你控制的设备才能作为连接器。默认不开放 CORS，不提供面向第三方的公共代理。

## 范围与播放

- 支持收藏夹和已加入的广播频道；不扫描私聊或群组。聊天文件夹只用于展开可选频道，不代表音频磁盘目录。
- 每个媒体库显式选择 1–20 个来源，每个来源读取最近 100 / 500 / 1000 / 2000 条**消息**中的音频。这个版本不是全历史曲库扫描。
- 聊天文件夹的结果是创建时的快照；此后新增频道不会自动加入。目录最多枚举 1000 个聊天。
- 支持作为文件上传的 FLAC、WAV、ALAC 等音频；不凭扩展名宣称 Hi-Res，实际规格以解码结果为准。单文件最多 4 GiB；客户端解码能力各不相同。
- 桌面端通过带认证的 HTTP Range 按需解码和跳转，不在连接器保存整首音频。传输缓冲有界。
- iOS 首次播放完整下载、验证后保存在本机，之后进入原生 EQ 播放链路；不宣称远程即点即播。可用“导入本地 / Telegram 下载文件夹”导入已有文件，属于一次性复制，不会监控 Telegram 缓存。
- 来源被删除、撤权、网络失败、内容保护开启或扫描失败时返回错误；桌面和 iOS 刷新保留旧索引。之前合法下载的本机副本不会由连接器自动删除。
- 提供文字赞助消息读取与展示回执；当前无法完整展示带照片/媒体的赞助消息，遇到这类频道会明确拒绝扫描/远程播放，提示使用官方客户端。没有屏蔽赞助消息的开关。
- Telegram 来源的曲目元数据不发送给云端 AI 选曲或偏好生成；本地选曲继续可用。请勿手动将 Telegram 内容粘贴到 AI 请求中，除非具备相应许可并满足平台条款。

公开可见或账号可访问不代表获得版权授权。[Telegram API 条款](https://core.telegram.org/api/terms)及[内容许可条款](https://telegram.org/tos/content-licensing)仍适用。连接器不是 Telegram 官方产品，当前实现不构成对所有客户端条款或应用商店审核要求的全面认证。对外发布前需评估其接入模式、赞助消息呈现和第三方客户端要求。

## 个人配置

两端支持导入同一版本的 JSON、XML、TXT：只填充表单，用户检查并填写凭据后才连接。配置不包含令牌、密码、会话或可执行脚本。不自动连接多个来源，不执行表达式。支持字段只有 `version`、`kind`、`name`、`url` 和可选 `username`。

Telegram 配置中的 `url` 是**选择完成后的媒体库地址**。可以在桌面来源卡片复制；iOS 在选择后表单中可见。地址中的媒体库 ID 不是访问令牌，服务仍要求 Bearer 认证。也可先手动填写连接器根地址并完成来源选择。

示例见 [`examples/`](examples/)，其中地址均为不可用的说明性占位地址，不含音乐资源。WebDAV 和 Plex 配置使用服务器根目录，Telegram 配置使用个人媒体库目录。

## 验证

```sh
Tools/telegram_connector/.venv/bin/python -m unittest discover -s Tools/telegram_connector -v
```

本地协议/界面联调，单独启动显式测试夹具：

```sh
Tools/telegram_connector/.venv/bin/python Tools/telegram_connector/fixture_server.py
```

夹具仅监听 `127.0.0.1:8766`，令牌固定为 `test-only-token`，提供自生成 WAV 和测试目录。它没有 Telegram 会话，不能用于真实部署，也不能作为真实账号验收证据。

运行 iOS 集成测试：

```sh
xcodebuild -project ios/Awake.xcodeproj -scheme AwakeIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  AWAKE_CONNECTOR_INTEGRATION=1 \
  -only-testing:AwakeTests/AwakeTests/testTelegramConnectorIntegrationWhenFixtureIsRunning test
```
