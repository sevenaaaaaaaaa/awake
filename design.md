# Awake 皮肤设计

这是可以直接导入“外观与皮肤”的设计文件。修改 JSON 后生成预览，确认后保存。
也可以保留需求文字，使用“AI 解读设计文档”转换为皮肤；该功能使用你配置的策展 AI 服务。

设计方向：中性黑阶、清晰的文字层级、克制的冰蓝强调色。封面保留作品本身的颜色。
不要把整页染成强调色。玻璃模式优先保证文字清晰，减少透明度的系统偏好应得到尊重。

```json
{
  "version": 1,
  "id": "custom",
  "name": "我的 Awake",
  "mode": "dark",
  "colors": {
    "bg": "#0c0d10",
    "surface": "#14161b",
    "raised": "#20232b",
    "text": "#f5f6fa",
    "muted": "#a5adbe",
    "accent": "#a9bcff",
    "onAccent": "#11182f",
    "border": "#303540"
  },
  "radius": 16,
  "density": "comfortable",
  "font": "system",
  "blur": 0
}
```

`mode` 支持 `dark`、`light`、`glass`；`radius` 为 0–28px，`blur` 为 0–40px。
`density` 支持 `comfortable`、`compact`；`font` 支持 `system`、`serif`。
颜色只接受六位十六进制值。正文与背景、卡片的对比度至少 4.5:1；按钮文字与强调色至少 4.5:1。

可从应用导出当前皮肤为 design.md，分享给社区后由对方自行导入。最多保存 30 份。
不执行皮肤里的 CSS、脚本或外部资源。皮肤可改变配色、材质、圆角、字体与密度，不替换业务逻辑。
