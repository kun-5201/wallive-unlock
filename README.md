# WalliveUnlock — 交互壁纸 免广告 + 会员解锁 IPA

针对「交互壁纸」(com.mutually.wallpaper)的免越狱改造版,基于原版
WalliveUnlock 越狱插件源码,打包成可直接签名的未加密 IPA。

## 功能

- 去广告:开屏(GDTSplashAd)、横幅(GDTUnifiedBannerView)、信息流
  (GDTNativeExpressAdView / GDTUnifiedNativeAdView)全部短路,横幅与
  信息流行随之塌缩;伪造会员响应里同时关闭 ios_ads_enabled
- 会员解锁:接管 /api/ios_access.php 返回本地伪造的永久 VIP;
  接管 /api/ios_download.php 绕过下载配额;绕过 ATTools 响应签名校验
- GDT 激励视频直接走失败路径(会员已解锁,无需看广告);
  快手激励视频保留可选观看
- 不显示悬浮日志按钮;无日志外发,全部本地生效

## 使用

1. 到 Actions 下载最新构建产物 Wallive-NoAds-VIP-ipa
2. 用全能签 / esign / SideStore 等工具签名安装(包内已移除全部签名)
3. 首次启动即生效,无需任何配置

## 构建

每次推送到 main 会自动构建:

- Theos 编译 WalliveUnlock/Tweak.xm → dylib(去掉了 CydiaSubstrate 依赖)
- 从官方企业分发 CDN 下载原版未加密 IPA
- 注入 dylib(主程序加 LC_LOAD_DYLIB),移除全部代码签名
- 在 App 包内写入默认配置(永久 VIP + 关广告)
- 产出未签名 IPA

本地构建:

```bash
cd WalliveUnlock && make          # 需要 Theos
python3 scripts/build_ipa.py .theos/obj/WalliveUnlock.dylib out.ipa
```

## 目录

- `WalliveUnlock/` — 插件源码(Tweak.xm、Makefile、control)
- `scripts/build_ipa.py` — 下载原包、注入、打包脚本
- `.github/workflows/ipa.yml` — CI 工作流

## 说明

- 原版 App 从官方渠道下载(walllive.18ir.cn),本仓库不含 App 本体
- 官方更新版本后,更新 build_ipa.py 里的 OFFICIAL_IPA_URL 即可
- 仅供学习研究
