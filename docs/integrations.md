# DAX 系统调用

应用标识为 `com.leco.dax`。先安装 `/Applications/DAX.app`，再使用以下入口。

## URL Scheme

- `dax://translate?text=Hello%20world` 翻译文字。text 使用 URL 编码。
- `dax://capture` 开始截图翻译。
- `dax://ocr` 开始截图 OCR。
- `dax://settings` 打开设置。

快捷指令可以用“URL”接“打开 URL”调用上述入口。快捷指令安装和 Raycast、PopClip 宿主内操作待实机验收。

## AppleScript

```applescript
tell application id "com.leco.dax"
    request "{\"path\":\"translate\",\"body\":{\"action\":\"translateText\",\"text\":\"Hello world\"}}"
end tell
```

`request` 返回 JSON。动作提交返回 `accepted`、`requestID` 和当前 `queryID`，实际服务结果异步产生。`requestID` 用于关联图片识别前后的同一脚本请求，`queryID` 会随内部翻译查询更新。通过状态查询获得 `busy`、`text`、`error` 及各服务的 `state`、`text`、`error`。

```applescript
tell application id "com.leco.dax" to request "{\"path\":\"status\"}"
```

`translate` 模块支持 `selectionTranslate`、`silentSelectionTranslate`、`silentInputBoxTranslate`、`snipTranslate`、`inputTranslate`、`pasteboardTranslate`、`showWindow`、`translateText`、`translateImage`。

`ocr` 模块支持 `snipOCR`、`continuousOCR`、`pasteboardOCR`、`showWindow`、`ocrImage`。截图及图片 OCR 支持 `isSilent`，静默结果写入剪贴板。图片内容以 `imageBase64` 传入。

`windowLocation` 可选 `mouse`、`center`、`statusIconBottom`、`last`。`inputBoxState` 可选 `alwaysFold`、`alwaysUnfold`、`last`。

`cancel` 模块取消当前任务。参数无效时返回 AppleScript 错误 -1700。网络及服务错误从状态查询返回。调用方应检查各服务状态并设置等待上限。

## 附带的集成文件

- `Integrations/Raycast/dax-translate.sh` 可作为 Raycast Script Command 导入。
- `Integrations/DAX.popclipext` 是选中文字后调用 DAX 的 PopClip 扩展目录。

接口行为参考 Bob 官方 AppleScript 文档，DAX 使用自己的应用标识和 URL Scheme。

[Bob AppleScript 文档](https://bobtranslate.com/guide/integration/applescript.html)

## 图片任务状态

`status` 的 `busy` 同时覆盖截图、文字翻译和图片区域任务。`images` 返回每张图片的状态、错误及各区域是否已有译文，调用方可据此等待完成、识别部分失败或确认取消。该状态字段不包含图片原文。
