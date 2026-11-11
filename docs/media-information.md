# 封面、歌词与听众乐评 · 桌面 0.6.2 / iOS 0.7.5

本轮提供用户确认后保存的资料整理流程，适用于已有的本地音乐、录音和远程曲目。

## 入口

- 桌面：曲目行的资料按钮，或右键曲目；沉浸播放页也有“整理封面、歌词与乐评”。
- iOS：长按曲目 → 整理封面、歌词与乐评；正在播放页可直接进入。

## 封面与本地资料

本地扫描优先读取内嵌图片，其次是与音频同名的 `.jpg/.jpeg/.png/.webp`，再读取目录中的 `cover`、`folder`、`front` 等图片。没有专辑信息的录音不会因为“专辑为空”就继承其他录音的封面。桌面重新扫描也会补上后来添加的相邻资料。

iOS 文件夹导入会读取可访问的相邻封面和歌词；只授权单个文件时，系统可能不允许读取旁边文件，可在编辑器手动选择。支持内嵌歌词、同名 `.lrc`、`.lyrics.txt` 和 UTF-8 文本导入，显示同步歌词或纯文本；同步歌词可点击跳转。

缺少图片时显示按标题稳定生成的抽象配图，可选夜色、山林、琥珀、暮色。配图由应用绘制，不调用 AI，不上传录音，不冒充原始专辑封面。用户也可导入自己的图片。iOS 有效图片会缩放缓存，实际图片封面同时用于系统正在播放信息。

## 在线匹配

1. 用户可先整理名称，或直接编辑曲名、艺人、专辑作为查询内容。
2. 主动查询 MusicBrainz 的录音候选，核对艺人、专辑、匹配分和时长。
3. 选择候选后，读取 Cover Art Archive 的封面、LRCLIB 的歌词及 CritiqueBrainz 的乐评。
4. 预览、调整并确认后保存到本机曲库。

MusicBrainz 暂不可用或没有结果时，尝试 LRCLIB 独立歌词候选。这些结果明确标为“歌词库候选”，不会推断 MusicBrainz 身份，不替换已有封面和乐评。某项资料失败时保留其他成功结果并显示说明。匹配分不是版本正确率或版权认证；时长差异超过 5 秒时提示核对现场版、节选或不同版本。

只发送用户填写的曲名、艺人，以及读取候选所需的专辑和时长。不上传音频、原始路径、服务器地址、Telegram 会话或来源凭据。不在导入和播放时自动进行外网查询。请求包含客户端标识，并限制频率、超时和响应大小。

## 听众乐评与注释

听众乐评与文件注释/个人备注独立。默认使用 CritiqueBrainz 的公开 API，区分 `recording`（单曲）和 `release_group`（专辑）；专辑评论明确标注“专辑乐评”。保留作者、正文、平台、原始链接及许可链接。

默认只接纳列明的 CC0、CC BY、CC BY-SA 许可记录；未知许可、保留所有权利或非商业许可的记录不自动导入。内容以文本呈现，不执行 HTML。无结果时保持空状态，不生成虚构评论。当前未接入网易云、QQ 等平台的非公开评论接口。

支持导入用户有权使用的评论 JSON 数组，最多 50 条。下面仅为字段占位示例，**不是实际乐评**：

```json
[
  {
    "author": "原作者署名",
    "text": "经授权导出的评论正文",
    "source": "原平台名称",
    "url": "https://example.invalid/original-review",
    "scope": "recording",
    "license": "实际许可或授权说明",
    "license_url": "https://example.invalid/license"
  }
]
```

`scope` 可为 `recording`、`release_group` 或 `imported`。实际展示及后续使用需要遵守对应内容的许可条件；公开可访问不代表可任意使用。

## 保存与恢复

显示名称、艺术家、专辑、封面、歌词、备注、来源说明、文件名建议和乐评保存在应用曲库。重新扫描保留用户确认过的资料，支持恢复首次整理前的信息；保存失败会恢复原有内存状态。

真实来源 ID、原始位置和音频文件保留。“来源说明”是用户备注，不覆盖真实出处。“文件名建议”供整理或导出参考；本版本不直接重命名磁盘/远程文件，不回写音频标签，避免破坏 NAS、Plex 和 Telegram 原始索引。

## 验证与限制

[验证记录](validation-media-information.log) · [iOS 编辑器截图](ios-screenshots/media-information.png)

测试使用自生成音频和图片，覆盖解析、持久化、恢复、刷新保留、录音封面隔离、编辑保存和继续播放。外网抽查中 LRCLIB 与 CritiqueBrainz 返回 HTTP 200，MusicBrainz 返回 HTTP 503；没有将服务不可用冒充完整匹配成功，真实专辑封面匹配仍需对应服务和曲目验收。

官方接口：[MusicBrainz 搜索](https://musicbrainz.org/doc/MusicBrainz_API/Search)、[限速](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)、[Cover Art Archive](https://musicbrainz.org/doc/Cover_Art_Archive/API)、[LRCLIB](https://lrclib.net/docs)、[CritiqueBrainz](https://critiquebrainz.readthedocs.io/api/endpoints.html)。
