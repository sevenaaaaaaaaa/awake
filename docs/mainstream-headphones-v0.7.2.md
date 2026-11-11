# iOS 主流耳机目录 0.7.2

75 个型号档案、18 个品牌分组；核对日期 2026-11-11。74 个厂商资料档案与 1 个“原道 / Vido（版本待确认）”登记入口。此数量表示资料与链路匹配覆盖，不代表 75 款都有实测 EQ，也不代表已用实物完成音质验收。

## 使用与匹配

声音 → 配置耳机与连接 → 参数、调音倾向与使用场景 → 选择耳机资料。按品牌筛选或搜索中文/英文别名。选择型号会清除上一个型号的手动参数、设备端音效描述与佩戴状态，保留个人聆听目标；同型号重选保留手动确认值。保存链路后才提交。

连接入口描述的是耳机音频能力。模拟耳机通过已绑定的小尾巴连接到 iPhone 时，链路可以是 USB；不会因为耳机为 3.5mm 就拒绝该组合。直接蓝牙真无线耳机的 USB 充电口不会被视为音频入口。

社区 EQ 查询使用明确的测量名称映射；中文别名先解析为具体型号。采用完整型号匹配，不以字符串包含关系匹配代际、Pro / 标准版、Hi-Fi / 标准版。已注明的 ANC 开/关、通透、模拟线条件必须与当前链路相符，未注明的耳套/耳垫/音量条件由用户核对后应用。Pro 3 社区拟合有独立的 ANC 开启要求。

设备端音效、厂商 App、自适应/空间处理单独记录。iOS 编码仍由系统协商；选择某型号不会解锁厂商专属编码、星闪、Wi-Fi 音频或 Android 手机专属功能。未收录的阻抗、灵敏度与输出数据保持空值，不从同芯片、同品牌或同代产品补齐。

原道登记入口不预置品牌统一调音、阻抗、灵敏度或 EQ 映射。请保存具体包装型号、渠道、插头、是否带麦与耳棉，再导入来源明确的参数。

## 品牌覆盖

| 品牌 | 档案数 |
|---|---:|
| Beats | 1 |
| Bose | 7 |
| Google Pixel | 2 |
| Nothing | 3 |
| OPPO | 4 |
| realme | 2 |
| vivo / iQOO | 4 |
| 一加 OnePlus | 2 |
| 三星 Samsung | 4 |
| 华为 HUAWEI | 9 |
| 原道 / Vido | 1 |
| 小米 / Redmi | 5 |
| 森海塞尔 Sennheiser | 6 |
| 水月雨 Moondrop | 5 |
| 索尼 Sony | 7 |
| 苹果 Apple | 9 |
| 荣耀 HONOR | 3 |
| 铁三角 Audio-Technica | 1 |

## 型号与出处

数据文件：`ios/Resources/headphones-v1.json`。目录为声明式 JSON，运行时校验版本、ID、别名冲突、数值与出处。加入资料不会自动创建或应用 EQ。

| 型号 | 音频入口 | 资料 |
|---|---|---|
| Sony WH-1000XM4 | 蓝牙、模拟线 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wh-1000xm4/specifications) |
| Sony WH-1000XM5 | 蓝牙、模拟线 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wh-1000xm5/specifications) |
| Sony WH-1000XM6 | 蓝牙、模拟线 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wh-1000xm6/specifications) |
| Sony WF-1000XM5 | 蓝牙 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wf-1000xm5/specifications) |
| Sony WF-1000XM6 | 蓝牙 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wf-1000xm6/specifications) |
| Sony WH-CH720N | 蓝牙、模拟线 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wh-ch720n/specifications) |
| Sony LinkBuds Open | 蓝牙 | [厂商资料](https://www.sony.com/electronics/support/wireless-headphones-bluetooth-headphones/wf-l910/specifications) |
| Bose QuietComfort 45 | 蓝牙、模拟线 | [厂商资料](https://www.bose.com/p/headphones/quietcomfort-45-headphones/QC45-HEADPHONEARN.html) |
| Bose QuietComfort Headphones 2023 | 蓝牙、模拟线 | [厂商资料](https://www.bose.com/p/headphones/quietcomfort-headphones/QC-HEADPHONEARN.html) |
| Bose QuietComfort Ultra Headphones | 蓝牙、模拟线 | [厂商资料](https://www.bose.com/p/headphones/bose-quietcomfort-ultra-headphones/QCUH-HEADPHONEARN.html) |
| Bose QuietComfort Ultra Headphones 2nd Gen | 蓝牙、模拟线、USB 音频 | [厂商资料](https://www.bose.com/p/headphones/bose-quietcomfort-ultra-headphones-2nd-gen/QCUH2-HEADPHONEARN.html) |
| Bose QuietComfort Ultra Earbuds | 蓝牙 | [厂商资料](https://www.bose.com/p/earbuds/bose-quietcomfort-ultra-earbuds/QCUE-HEADPHONEIN.html) |
| Bose QuietComfort Ultra Earbuds 2nd Gen | 蓝牙 | [厂商资料](https://support.bose.co.uk/article/quietcomfort-ultra-earbuds-gen-2-specifications) |
| Bose Ultra Open Earbuds | 蓝牙 | [厂商资料](https://www.bose.com/p/earbuds/bose-ultra-open-earbuds/ULT-HEADPHONEOPN.html) |
| Sennheiser HD 600 | 模拟线 | [厂商资料](https://us.sennheiser-hearing.com/products/hd-600) |
| Sennheiser HD 560S | 模拟线 | [厂商资料](https://us.sennheiser-hearing.com/products/hd-560s) |
| Sennheiser IE 200 | 模拟线 | [厂商资料](https://us.sennheiser-hearing.com/products/ie-200) |
| Sennheiser MOMENTUM 4 Wireless | 蓝牙、模拟线、USB 音频 | [厂商资料](https://us.sennheiser-hearing.com/products/momentum-4-wireless) |
| Sennheiser MOMENTUM True Wireless 4 | 蓝牙 | [厂商资料](https://us.sennheiser-hearing.com/products/momentum-true-wireless-4) |
| Sennheiser ACCENTUM Plus Wireless | 蓝牙、模拟线、USB 音频 | [厂商资料](https://us.sennheiser-hearing.com/products/accentum-plus-wireless) |
| Moondrop CHU II | 模拟线 | [厂商资料](https://moondroplab.com/en-products/chu-ii) |
| Moondrop ARIA 2 | 模拟线 | [厂商资料](https://moondroplab.com/en/products/aria2) |
| Moondrop KATO | 模拟线 | [厂商资料](https://moondroplab.com/en/products/kato) |
| Moondrop MAY | USB 音频、模拟线 | [厂商资料](https://moondroplab.com/en/products/may) |
| Moondrop Space Travel | 蓝牙 | [厂商资料](https://moondroplab.com/en/products/space-travel) |
| Audio-Technica ATH-AD2000X | 模拟线 | [厂商资料](https://www.audio-technica.com/en-us/ath-ad2000x) |
| Beats Studio Pro | 蓝牙、模拟线、USB 音频 | [厂商资料](https://www.beatsbydre.com/support/headphones/studio-pro) |
| Apple AirPods Pro 2 | 蓝牙 | [厂商资料](https://support.apple.com/109525) |
| Apple AirPods Pro 3 | 蓝牙 | [厂商资料](https://support.apple.com/109525) |
| Apple AirPods 4 | 蓝牙 | [厂商资料](https://support.apple.com/109525) |
| Apple AirPods 4 ANC | 蓝牙 | [厂商资料](https://support.apple.com/109525) |
| Apple AirPods Max 2020 | 蓝牙、模拟线 | [厂商资料](https://support.apple.com/109525) |
| Apple AirPods Max USB-C 2024 | 蓝牙、USB 音频 | [厂商资料](https://support.apple.com/109525) |
| Apple AirPods Max 2 | 蓝牙、USB 音频 | [厂商资料](https://support.apple.com/109525) |
| Apple EarPods USB-C | USB 音频 | [厂商资料](https://www.apple.com/shop/product/mtjy3am/a/earpods-usb-c) |
| Apple EarPods 3.5mm | 模拟线 | [厂商资料](https://www.apple.com/shop/product/mnhf2am/a/earpods-35mm-headphone-plug) |
| Samsung Galaxy Buds2 Pro | 蓝牙 | [厂商资料](https://www.samsung.com/us/support/owners/product/galaxy-buds2-pro/) |
| Samsung Galaxy Buds3 Pro | 蓝牙 | [厂商资料](https://www.samsung.com/fr/support/mobile-devices/what-are-the-differences-between-the-galaxy-buds4-pro-buds4-and-galaxy-buds3-pro-buds3/) |
| Samsung Galaxy Buds4 Pro | 蓝牙 | [厂商资料](https://www.samsung.com/fr/support/mobile-devices/what-are-the-differences-between-the-galaxy-buds4-pro-buds4-and-galaxy-buds3-pro-buds3/) |
| Samsung Galaxy Buds3 FE | 蓝牙 | [厂商资料](https://www.samsung.com/us/mobile-audio/galaxy-buds/compare/) |
| Xiaomi Buds 5 | 蓝牙 | [厂商资料](https://www.mi.com/global/product/xiaomi-buds-5/) |
| Xiaomi Buds 5 Pro | 蓝牙 | [厂商资料](https://www.mi.com/global/product/xiaomi-buds-5-pro/) |
| Redmi Buds 5 Pro | 蓝牙 | [厂商资料](https://www.mi.com/global/product/redmi-buds-5-pro/) |
| Redmi Buds 6 | 蓝牙 | [厂商资料](https://www.mi.com/global/product/redmi-buds-6/) |
| Redmi Buds 6 Pro | 蓝牙 | [厂商资料](https://www.mi.com/global/product/redmi-buds-6-pro/) |
| HUAWEI FreeBuds Pro 3 | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| HUAWEI FreeBuds Pro 4 | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| HUAWEI FreeBuds Pro 5 | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/headphones/freebuds-pro-5/) |
| HUAWEI FreeBuds 6i | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| HUAWEI FreeBuds 7i | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| HUAWEI FreeBuds 6 | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| HUAWEI FreeClip | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| HUAWEI FreeClip 2 | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/headphones/freeclip2/) |
| HUAWEI FreeBuds SE 3 | 蓝牙 | [厂商资料](https://consumer.huawei.com/cn/support/content/zh-cn00759656/) |
| OPPO Enco X2 | 蓝牙 | [厂商资料](https://www.oppo.com/uk/accessories/oppo-enco-x/specs/) |
| OPPO Enco X3 | 蓝牙 | [厂商资料](https://www.oppo.com/cn/headphones/) |
| OPPO Enco Air4 Pro | 蓝牙 | [厂商资料](https://www.oppo.com/en/accessories/enco-air4-pro/) |
| OPPO Enco X3s | 蓝牙 | [厂商资料](https://www.oppo.com/uk/accessories/oppo-enco-x/specs/) |
| OnePlus Buds Pro 3 | 蓝牙 | [厂商资料](https://www.oneplus.com/us/product/product/oneplus-buds-pro-3) |
| OnePlus Buds 4 | 蓝牙 | [厂商资料](https://www.oneplus.com/us/oneplus-buds-4) |
| vivo TWS 4 | 蓝牙 | [厂商资料](https://www.vivo.com.cn/vivo/param/vivotws4) |
| vivo TWS 4 Hi-Fi | 蓝牙 | [厂商资料](https://www.vivo.com.cn/vivo/param/vivotws4hifi) |
| vivo TWS 5 | 蓝牙 | [厂商资料](https://www.vivo.com.cn/vivo/param/vivotws5) |
| iQOO TWS 5 | 蓝牙 | [厂商资料](https://www.vivo.com.cn/vivo/iqootws5/) |
| HONOR Earbuds 3 Pro | 蓝牙 | [厂商资料](https://www.honor.com/cn/support/content/zh-cn15904928/) |
| HONOR Earbuds 4 | 蓝牙 | [厂商资料](https://www.honor.com/cn/support/content/zh-cn15904928/) |
| HONOR Earbuds Open | 蓝牙 | [厂商资料](https://www.honor.com/cn/support/content/zh-cn15904928/) |
| realme Buds Air6 | 蓝牙 | [厂商资料](https://www.realme.com/ru/newsroom/Air6) |
| realme Buds Air6 Pro | 蓝牙 | [厂商资料](https://www.realme.com/ru/newsroom/Air6) |
| Google Pixel Buds Pro 2 | 蓝牙 | [厂商资料](https://support.google.com/googlepixelbuds/answer/10595435?hl=en-IN) |
| Google Pixel Buds 2a | 蓝牙 | [厂商资料](https://support.google.com/googlepixelbuds/answer/10595435?hl=en-IN) |
| Nothing Ear 2024 | 蓝牙 | [厂商资料](https://checkout-au.nothing.tech/pages/about) |
| Nothing Ear (a) | 蓝牙 | [厂商资料](https://checkout-eu.nothing.tech/products/ear-a) |
| Nothing Ear (3) | 蓝牙 | [厂商资料](https://us.nothing.tech/llms.txt) |
| 原道 / Vido（版本待确认） | 模拟线 | 版本待确认，未预置测量 |

公开测量目录来源：[AutoEq results](https://github.com/jaakkopasanen/AutoEq/tree/master/results)。它汇总不同测量者、仪器和条件，不是个人实物测量。
