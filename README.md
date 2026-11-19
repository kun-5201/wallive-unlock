# WalliveUnlock

## 中文

WalliveUnlock 是 Wallive（交互壁纸，`com.mutually.wallpaper`）的辅助插件，只做两件事：导出设备密钥，和从本地缓存导出壁纸包（`.tendies`）；同时提供悬浮日志与请求记录（`debug.log`），方便排查问题。

它不改会员、不去广告、不伪造任何服务器响应、不碰网络。配对和下载请用原版 App：不装插件时 App 正常工作，装了插件反而可能无法配对——需要导出时再注入，导完就卸掉。

安装：用全能签等工具把 dylib 注入原版 App 即可，无需越狱。

## English

WalliveUnlock is a helper plugin for Wallive (com.mutually.wallpaper). It does two things only: export the device key, and export wallpaper packages (`.tendies`) from the local cache — plus a floating log overlay and request logging (`debug.log`) for troubleshooting.

It does not touch membership, ads, or any server response, and it hooks no network calls. Use the stock app for pairing and downloads: the app works fine without the plugin, and may fail to pair with it installed — inject the plugin only when you need an export, then remove it.

Install: inject the dylib into the stock app with a signer such as 全能签. No jailbreak required.
