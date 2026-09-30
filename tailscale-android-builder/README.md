# tailscale-android 自构建

CI 检出上游 [tailscale-android](https://github.com/tailscale/tailscale-android) 后，在编译前执行 `scripts/apply-headscale-customization.sh`，合入 Headscale 定制：

- **未登录**：主界面弹出 JSON 配置（`login-server`、`auth-key`），每次处于 `NeedsLogin` 都会出现。
- **开机**：`BootCompletedReceiver` 静默执行——有已保存配置则 auth-key 登录并 `startVPN()`；否则对已登录设备尝试 `StartVPNWorker`。
- 配置保存在应用私有 `SharedPreferences`，不校验 URL 格式，仅要求两个字段非空。

升级上游 ref 时若 `patches/headscale-customization.patch` 应用失败，需按新标签重新生成补丁。

```json
{
  "login-server": "https://headscale.example.com",
  "auth-key": "tskey-auth-..."
}
```

首次使用仍需在系统里授予 VPN 权限；部分 ROM 还需手动允许「自启动」与关闭省电限制。
