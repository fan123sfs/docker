# freerdp-android 自构建

CI 检出上游 [FreeRDP](https://github.com/FreeRDP/FreeRDP) 后，在编译前执行 `scripts/apply-customization.sh`，合入定制：

- **应用名**：桌面与启动器显示为 `freerdp`，RDP 客户端名同为 `freerdp`
- **图标**：绿色 Android 风格启动图标
- **更多菜单**：溢出菜单 **JSON 远程桌面**，可粘贴 JSON 批量导入书签（会替换现有书签列表）

升级上游 ref 时若 `patches/afreerdp-customization.patch` 应用失败，需按新标签重新生成补丁。

## JSON 格式

支持对象（推荐）或数组：

```json
{
  "bookmarks": [
    {
      "label": "办公室",
      "hostname": "192.168.1.10",
      "port": 3389,
      "username": "admin",
      "password": "secret",
      "domain": ""
    },
    {
      "label": "机房",
      "hostname": "10.0.0.5",
      "port": 3389,
      "username": "root",
      "password": "",
      "domain": "WORKGROUP"
    }
  ]
}
```

`hostname` 必填；`port` 默认 `3389`。保存后会写入本地偏好并刷新主界面列表。
