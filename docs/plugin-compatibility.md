# Bob 插件兼容与验证

DAX 的插件接口以 Bob 1.21.2 的公开插件文档为基准。插件在单独子进程中运行，取消或超时可以结束插件进程。插件选项存入 DAX 专用钥匙串条目。

## 已实现接口

- `info.json`、`main.js`、CommonJS `require`、`module.exports`、`exports`、`__filename` 与 `__dirname`。
- `supportLanguages`、`supportBoundingBox`、`translate`、`ocr`、`tts`、`pluginValidate` 和 `pluginTimeoutInterval`。
- 旧版 completion 回调与新版 `query.onCompletion`、`query.onStream`、`query.cancelSignal`、`query.originalText`。
- `$option`、`$info`、`$env`、`$log`、`$signal`、`$timer`、`$data`、`$file`、`$http`。
- 内置 `crypto-js 4.2.0` 和 `$util`，crypto-js 的 MIT 许可与脚本一起保留。
- HTTP 回调及 Promise、JSON/表单/原始二进制/多段上传、逐块流式响应、取消和超时。
- 翻译的普通文本、Markdown、旧版 `toParagraphs`、`toDict` 字典内容与 `thinkInfo` 数据。
- OCR 扁平及区域/段落结构，保留 Bob 顶部原点的四点坐标，并提供应用使用的底部原点归一化矩形。
- TTS 的 URL 和 Base64 音频结果。
- `.bobplugin` 安装、停用、移除、选项配置、appcast 更新查询和校验后手动更新。

## 查询字段和语言代码

实时查询分别传递预处理后的 `text` 和预处理前的 `originalText`。`from`、`to` 保留用户选择的 `auto` 或指定语言，`detectFrom`、`detectTo` 传递解析后的语言。重试保留本次原始输入，编辑文字后采用新的原始输入。图片区域使用该区域文字。

历史记录目前只保存整理后的文字，复用历史时以已保存文字作为原始输入。完整原始排版无法从这些记录恢复。

语言选项覆盖官方公开表中的 390 个代码，包括自动选项、粤语、文言文、葡萄牙语地区变体及塞尔维亚语书写变体。常用语言排在前面，结果窗口其余选项收纳在“更多语言”。具体服务支持范围由对应服务确定。

真实插件子进程回归覆盖原始文字、自动及指定语言、重试、编辑和历史复用。语言配置导入覆盖特殊语言代码。

[Bob 语言代码表](https://bobtranslate.com/plugin/addition/language.html)

## 文件和网络边界

插件根目录只读，`$sandbox/` 对应插件专属可写目录。路径解析拒绝目录穿越和符号链接越界。安装包限制为 64 MB、5000 个文件，拒绝加密 ZIP、多卷 ZIP、特殊文件和重复路径。HTTP 响应限制为 32 MB。插件单次执行的写入总量限制为 64 MB。

HTTP 重定向到其他站点时移除非公开请求头。TLS 使用系统证书验证。更新包需要匹配 appcast 的 SHA256、插件标识和版本。

## 尚有差异的接口

WebSocket 支持打开、关闭、文本、二进制、连接状态和心跳检测。URLSession 自动处理入站 ping，当前没有向插件暴露原始 ping 帧、带自定义负载的 ping/pong 和手动 pong 发送。`allowSelfSignedSSLCertificates` 不会关闭系统证书验证。

动态图标、关键选项改变名称的 UI 行为仍需主界面集成验证。所有第三方插件的完整兼容性需要逐个实际验证。这里记录的网络验证使用本机测试服务，供应商账号和真实远程请求由对应服务验收覆盖。

## 验证方法

运行 `Tests/run-plugin-checks.sh`。测试包含真实子进程、CommonJS、crypto-js、二进制、沙盒、HTTP、流式响应、翻译/OCR/TTS 回调、定时器、信号和死循环取消。

以下原始公开插件通过本机模拟服务的契约验证。

| 插件 | 原始版本或提交 | 验证 |
| --- | --- | --- |
| nextai-translator OpenAI Translator | 5.0.1，发布包 SHA256 e5f7afe1f24264bc7a86d0734c009d6091a7777b7b01b1238f3400bb1a17556f | ZIP 安装、支持语言、非流式和流式翻译 |
| Henry-Jessie LLM OCR | d36354ac9483f877752c23e701ddaa912942e179 | 原始脚本加载、图片数据、HTTP 请求和 OCR 返回值 |
| BiboyQG Cosyvoice | 8acf7672f3785f2ccc449bfab8d88ec99bdf1f6d | 原始脚本加载、GET 查询参数、二进制音频返回值 |

可用 `DAX_REAL_PLUGIN`、`DAX_REAL_OCR_PLUGIN` 和 `DAX_REAL_TTS_PLUGIN` 环境变量指定上述原始公开插件的本地包或目录，再运行相同测试脚本。测试只向本机地址发送合成输入。

## 公开接口来源

- [插件元信息](https://bobtranslate.com/plugin/quickstart/info.html)
- [翻译协议](https://bobtranslate.com/plugin/quickstart/translate.html)
- [OCR 协议](https://bobtranslate.com/plugin/quickstart/ocr.html)
- [TTS 协议](https://bobtranslate.com/plugin/quickstart/tts.html)
- [HTTP 接口](https://bobtranslate.com/plugin/api/http.html)
- [文件接口](https://bobtranslate.com/plugin/api/file.html)
- [翻译结果](https://bobtranslate.com/plugin/object/translateresult.html)
- [OCR 结果](https://bobtranslate.com/plugin/object/ocrresult.html)
- [WebSocket 接口](https://bobtranslate.com/plugin/api/websocket.html)
