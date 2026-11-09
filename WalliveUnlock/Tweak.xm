// WalliveUnlock — 交互壁纸（com.mutually.wallpaper）本地会员解锁
// 1) 接管 /api/ios_access.php，返回本地伪造的 RemoteAccessResponse（VIP）
// 2) 接管 /api/ios_download.php（forgeDownload / localFirst / autoRepair）
//    额度弹窗根因：服务端按设备签名+配额拒绝，客户端见到 daily/weekly_limit_reached 即弹窗。
//    修复方式：用公开的 get_wallpaper.php 把 wallpaper_id 动态解析成 /admin/uploads 媒体直链，
//    本地返回 {"ok":true,"down_url":...}，不再依赖服务端发 token。
// 3) 兜底 patch ATHelper(ATTools) 的响应签名校验
// 无日志、无网络外发，全部读取本地配置。

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Security/Security.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreGraphics/CoreGraphics.h>

static NSDictionary *WUConfig(void);
static NSString *WUWritableDir(void);
static NSArray<NSString *> *WUDirs(void);
static CGSize WUDevicePixelSize(void);

static NSString *const kWUHandledKey       = @"WUHandled";
static NSString *const kWUAccessPath       = @"/api/ios_access.php";
static NSString *const kWUDownloadPath     = @"/api/ios_download.php";
static NSString *const kWUTemplateTag      = @"\"_v\": 6";
static NSString *const kWUBaseURL          = @"https://walllive.18ir.cn";
static NSString *const kWUListPath         = @"/api/get_wallpaper.php";
static NSString *const kWUFileDownloadPath = @"/api/ios_download_file.php";

#pragma mark - 本地 .tendies 生成

static uint32_t gCRC[256];
static void WUCRCInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            gCRC[i] = c;
        }
    });
}
static uint32_t WUCRC32(const uint8_t *p, size_t n) {
    WUCRCInit();
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = gCRC[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

static void WUAppend16(NSMutableData *d, uint16_t v) { [d appendBytes:&v length:2]; }
static void WUAppend32(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; }

@interface WUZip : NSObject
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, strong) NSMutableData *central;
@property (nonatomic, assign) NSUInteger count;
@end

@implementation WUZip
- (instancetype)init { if (self = [super init]) { _body = [NSMutableData data]; _central = [NSMutableData data]; } return self; }

- (void)addPath:(NSString *)path data:(NSData *)data {
    NSData *name = [path dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t crc = WUCRC32((const uint8_t *)data.bytes, data.length);
    uint32_t off = (uint32_t)self.body.length;

    // local header
    WUAppend32(self.body, 0x04034b50);
    WUAppend16(self.body, 20);      // version
    WUAppend16(self.body, 0);       // flags
    WUAppend16(self.body, 0);       // method store
    WUAppend16(self.body, 0); WUAppend16(self.body, 0); // time/date
    WUAppend32(self.body, crc);
    WUAppend32(self.body, (uint32_t)data.length);
    WUAppend32(self.body, (uint32_t)data.length);
    WUAppend16(self.body, (uint16_t)name.length);
    WUAppend16(self.body, 0);
    [self.body appendData:name];
    [self.body appendData:data];

    // central
    WUAppend32(self.central, 0x02014b50);
    WUAppend16(self.central, 20); WUAppend16(self.central, 20);
    WUAppend16(self.central, 0); WUAppend16(self.central, 0);
    WUAppend16(self.central, 0); WUAppend16(self.central, 0);
    WUAppend32(self.central, crc);
    WUAppend32(self.central, (uint32_t)data.length);
    WUAppend32(self.central, (uint32_t)data.length);
    WUAppend16(self.central, (uint16_t)name.length);
    WUAppend16(self.central, 0); WUAppend16(self.central, 0);
    WUAppend16(self.central, 0); WUAppend16(self.central, 0);
    WUAppend32(self.central, 0);
    WUAppend32(self.central, off);
    [self.central appendData:name];
    self.count++;
}

- (NSData *)finish {
    NSMutableData *out = [self.body mutableCopy];
    uint32_t cdOff = (uint32_t)out.length;
    [out appendData:self.central];
    WUAppend32(out, 0x06054b50);
    WUAppend16(out, 0); WUAppend16(out, 0);
    WUAppend16(out, (uint16_t)self.count); WUAppend16(out, (uint16_t)self.count);
    WUAppend32(out, (uint32_t)self.central.length);
    WUAppend32(out, cdOff);
    WUAppend16(out, 0);
    return out;
}
@end

static NSData *WUJPEGFromCGImage(CGImageRef img, size_t tw, size_t th, CGFloat quality) {
    if (!img || tw == 0 || th == 0) return nil;
    size_t sw = CGImageGetWidth(img), sh = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, tw, th, 8, tw * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGFloat scale = MAX((CGFloat)tw / (CGFloat)sw, (CGFloat)th / (CGFloat)sh);
    CGFloat dw = sw * scale, dh = sh * scale;
    CGRect dst = CGRectMake((tw - dw) / 2.0, (th - dh) / 2.0, dw, dh);
    CGContextDrawImage(ctx, dst, img);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!out) return nil;
#if TARGET_OS_IPHONE
    UIImage *ui = [UIImage imageWithCGImage:out];
    NSData *d = UIImageJPEGRepresentation(ui, quality);
#else
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:out];
    NSData *d = [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: @(quality)}];
#endif
    CGImageRelease(out);
    return d;
}


// auto-generated templates


static NSData *WUPlistsXML(id obj) {
    return [NSPropertyListSerialization dataWithPropertyList:obj format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
}

static NSData *WUProviderInfo(void) {
    NSArray *objects = @[
        @"$null",
        @{@"$classname": @"NSDate", @"$classes": @[@"NSDate", @"NSObject"]},
        @{@"$classname": @"NSMutableDictionary", @"$classes": @[@"NSMutableDictionary", @"NSDictionary", @"NSObject"],
          @"NS.keys": @[@{@"CF$UID": @3}], @"NS.objects": @[@{@"CF$UID": @4}]},
        @"kConfigurationLastUseDateKey",
        @{@"$class": @{@"CF$UID": @1}, @"NS.time": @([NSDate date].timeIntervalSinceReferenceDate)}
    ];
    return WUPlistsXML(@{@"$version": @100000, @"$archiver": @"NSKeyedArchiver",
                         @"$top": @{@"root": @{@"CF$UID": @2}}, @"$objects": objects});
}




static NSData *WUPNGFromCGImage(CGImageRef img, size_t tw, size_t th) {
    if (!img || tw == 0 || th == 0) return nil;
    size_t sw = CGImageGetWidth(img), sh = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, tw, th, 8, tw * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGFloat sc = MAX((CGFloat)tw / (CGFloat)sw, (CGFloat)th / (CGFloat)sh);
    CGFloat dw = sw * sc, dh = sh * sc;
    CGContextDrawImage(ctx, CGRectMake((tw - dw) / 2.0, (th - dh) / 2.0, dw, dh), img);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!out) return nil;
    NSData *d = nil;
#if TARGET_OS_IPHONE
    d = UIImagePNGRepresentation([UIImage imageWithCGImage:out]);
#else
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:out];
    d = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
#endif
    CGImageRelease(out);
    return d;
}

static NSString *WUCamlStates(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"    <states>\n"];
    for (NSString *n in @[@"Locked Light", @"Unlock Light", @"Sleep Light",
                          @"Locked Dark", @"Unlock Dark", @"Sleep Dark"]) {
        [out appendFormat:
          @"      <LKState name=\"%@\">\n        <elements>\n"
           "          <LKStateSetValue targetId=\"vid\" keyPath=\"opacity\">\n            <value type=\"integer\" value=\"1\"/>\n          </LKStateSetValue>\n"
           "          <LKStateSetValue targetId=\"vid\" keyPath=\"position.x\">\n            <value type=\"integer\" value=\"195\"/>\n          </LKStateSetValue>\n"
           "          <LKStateSetValue targetId=\"vid\" keyPath=\"position.y\">\n            <value type=\"integer\" value=\"422\"/>\n          </LKStateSetValue>\n"
           "        </elements>\n      </LKState>\n", n];
    }
    [out appendString:@"    </states>\n"];
    return out;
}

static NSString *WUCamlTransitions(void) {
    NSMutableString *out = [NSMutableString stringWithString:@"    <stateTransitions>\n"];
    for (NSString *n in @[@"Unlock Light", @"Locked Light", @"Sleep Light",
                          @"Unlock Dark", @"Locked Dark", @"Sleep Dark"]) {
        [out appendFormat:
          @"      <LKStateTransition fromState=\"*\" toState=\"%@\">\n        <elements>\n"
           "          <LKStateTransitionElement targetId=\"vid\" key=\"opacity\">\n"
           "            <animation type=\"CASpringAnimation\" damping=\"50\" mass=\"2\" stiffness=\"300\" velocity=\"0\" duration=\"0.8\" fillMode=\"backwards\" keyPath=\"opacity\" mica_autorecalculatesDuration=\"1\"/>\n"
           "          </LKStateTransitionElement>\n"
           "        </elements>\n      </LKStateTransition>\n", n];
    }
    [out appendString:@"    </stateTransitions>\n"];
    return out;
}

static NSString *WUFramesCaml(double wPt, double hPt, NSArray<NSString *> *names, double fps) {
    (void)fps;
    return [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
         "<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\">\n"
         "  <CALayer id=\"__capRootLayer__\" name=\"CAPlayground Root Layer\" bounds=\"0 0 %g %g\" position=\"%g %g\" zPosition=\"0\" geometryFlipped=\"0\" opacity=\"1\" transform.rotation.z=\"0\" transform.rotation.x=\"0\" transform.rotation.y=\"0\" transform=\"rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)\" backgroundColor=\"0 0 0 1\" cornerRadius=\"0\" allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" cornerCurve=\"circular\">\n"
         "    <sublayers>\n"
         "      <CALayer id=\"vid\" name=\"video\" bounds=\"0 0 %g %g\" position=\"%g %g\" zPosition=\"0\" geometryFlipped=\"0\" opacity=\"1\" transform.rotation.z=\"0\" transform.rotation.x=\"0\" transform.rotation.y=\"0\" transform=\"rotate(0deg) rotate(0deg, 0, 1, 0) rotate(0deg, 1, 0, 0)\" cornerRadius=\"0\" allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" cornerCurve=\"circular\">\n"
         "        <contents>\n          <CGImage src=\"assets/%@\"/>\n        </contents>\n"
         "      </CALayer>\n"
         "    </sublayers>\n"
         "    <modules/>\n"
         "%@%@"
         "  </CALayer>\n</caml>\n",
        wPt, hPt, wPt/2, hPt/2,
        wPt, hPt, wPt/2, hPt/2,
        names.firstObject, WUCamlStates(), WUCamlTransitions()];
}

static NSString *WUEmptyCamlDoc(void) {
    return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\">\n"
            "  <CALayer id=\"__root__\" name=\"Root Layer\" bounds=\"0 0 390 844\" position=\"195 422\" geometryFlipped=\"0\" opacity=\"1\" transform=\"rotate(0deg)\" backgroundColor=\"0 0 0 0\" cornerRadius=\"0\" allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" cornerCurve=\"circular\">\n"
            "    <sublayers/>\n"
            "    <states>\n"
            "      <LKState name=\"Locked\"><elements/></LKState>\n"
            "      <LKState name=\"Unlock\"><elements/></LKState>\n"
            "      <LKState name=\"Sleep\"><elements/></LKState>\n"
            "    </states>\n"
            "  </CALayer>\n</caml>\n";
}

static NSString *WUIndexXMLDoc(void) {
    return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\">\n<dict>\n  <key>rootDocument</key>\n  <string>main.caml</string>\n</dict>\n</plist>\n";
}

static NSString *WUAssetManifestDoc(void) {
    return @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\n"
            "<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\">\n"
            "  <MicaAssetManifest>\n    <modules type=\"NSArray\"/>\n  </MicaAssetManifest>\n</caml>\n";
}

// 用真实包（DuoDynamic 外壳）生成：只替换图片资源
static NSData *WUBuildShellTendies(NSURL *mediaURL, NSInteger wallpaperID) {
    NSString *shell = nil;
    for (NSString *d in WUDirs()) {
        NSString *c = [d stringByAppendingPathComponent:@"shell/descriptors"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:c]) { shell = [d stringByAppendingPathComponent:@"shell"]; break; }
    }
    if (!shell) return nil;

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    if (!asset) return nil;
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = CMTimeMake(1, 5);
    gen.requestedTimeToleranceAfter = CMTimeMake(1, 5);
    CGImageRef img = [gen copyCGImageAtTime:CMTimeMakeWithSeconds(0.1, 600) actualTime:NULL error:NULL];
    if (!img) return nil;
    CGImageRef img2 = CGImageRetain(img);
    NSData *png = WUJPEGFromCGImage(img, 1170, 2532, 0.92);
    CGImageRelease(img);
    if (!png) return nil;

    NSString *oldUUID = nil;
    NSArray *top = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[shell stringByAppendingPathComponent:@"descriptors"] error:nil];
    for (NSString *n in top) if (n.length == 36) { oldUUID = n; break; }
    if (!oldUUID) return nil;
    NSString *newUUID = [[NSUUID UUID].UUIDString uppercaseString];   // 新身份，避免与已安装模板冲突

    WUZip *zip = [WUZip new];
    NSMutableSet<NSString *> *assetRefs = [NSMutableSet set];   // "camldir|assetName"
    NSMutableArray<NSString *> *stack = [NSMutableArray arrayWithObject:shell];
    NSFileManager *fm = [NSFileManager defaultManager];
    while (stack.count) {
        NSString *dir = stack.lastObject;
        [stack removeLastObject];
        for (NSString *n in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            NSString *full = [dir stringByAppendingPathComponent:n];
            BOOL isDir = NO;
            [fm fileExistsAtPath:full isDirectory:&isDir];
            if (isDir) { [stack addObject:full]; continue; }

            NSString *rel = [full substringFromIndex:shell.length + 1];
            NSString *outPath = [rel stringByReplacingOccurrencesOfString:oldUUID withString:newUUID];

            NSData *data = nil;
            NSString *ext = n.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"png"]) {
                data = WUPNGFromCGImage(img2, 1170, 2532);
            } else if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
                data = png;
            } else if ([n isEqualToString:@"com.apple.posterkit.provider.descriptor.identifier"]) {
                data = [newUUID dataUsingEncoding:NSUTF8StringEncoding];
            } else {
                data = [NSData dataWithContentsOfFile:full];
                if ([ext isEqualToString:@"caml"] && data.length) {
                    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"assets/([A-Za-z0-9_.\\-]+)" options:0 error:nil];
                    for (NSTextCheckingResult *m in [re matchesInString:txt options:0 range:NSMakeRange(0, txt.length)]) {
                        if (m.numberOfRanges > 1) {
                            NSString *dirRel = [rel stringByDeletingLastPathComponent];
                            [assetRefs addObject:[NSString stringWithFormat:@"%@|%@", dirRel, [txt substringWithRange:[m rangeAtIndex:1]]]];
                        }
                    }
                }
            }
            if (data.length) [zip addPath:outPath data:data];
        }
    }
    // 补上 caml 引用但模板里没有的资源
    for (NSString *ref in assetRefs) {
        NSArray *parts = [ref componentsSeparatedByString:@"|"];
        if (parts.count != 2) continue;
        NSString *outRel = [[parts[0] stringByAppendingPathComponent:@"assets"]
                            stringByAppendingPathComponent:parts[1]];
        outRel = [outRel stringByReplacingOccurrencesOfString:oldUUID withString:newUUID];
        NSString *aext = [parts[1] pathExtension].lowercaseString;
        NSData *adata = [aext isEqualToString:@"png"] ? WUPNGFromCGImage(img2, 1170, 2532)
                                                      : WUJPEGFromCGImage(img2, 1170, 2532, 0.92);
        if (adata.length) [zip addPath:outRel data:adata];
    }
    if (img2) CGImageRelease(img2);
    return [zip finish];
}

static NSData *WUBuildLayeredTendies(NSURL *mediaURL, NSInteger wallpaperID) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    if (!asset) return nil;
    double seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds <= 0) return nil;

    const double wPt = 390, hPt = 844;
    const double fps = 4.0;
    NSUInteger frameCount = (NSUInteger)floor(seconds * fps);
    if (frameCount == 0) frameCount = 1;
    if (frameCount > 48) frameCount = 48;

    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = CMTimeMake(1, 5);
    gen.requestedTimeToleranceAfter = CMTimeMake(1, 5);

    NSString *wu = [[NSUUID UUID].UUIDString uppercaseString];
    NSString *name = [NSString stringWithFormat:@"w%ld", (long)wallpaperID];
    NSString *res = [NSString stringWithFormat:@"%gw-%gh@3x~iphone", wPt, hPt];
    NSString *wpFolder = [NSString stringWithFormat:@"7400.Custom-%@.wallpaper", res];
    NSString *bgCA = [NSString stringWithFormat:@"7400.Custom_Background-%@.ca", res];
    NSString *flCA = [NSString stringWithFormat:@"7400.Custom_Floating-%@.ca", res];
    NSString *fgCA = [NSString stringWithFormat:@"7400.Custom_Foreground-%@.ca", res];
    NSString *base = [NSString stringWithFormat:@"descriptors/%@", wu];
    NSString *v1 = [base stringByAppendingPathComponent:@"versions/1"];
    NSString *contents = [v1 stringByAppendingPathComponent:@"contents"];
    NSString *wpDir = [contents stringByAppendingPathComponent:wpFolder];
    NSString *bgDir = [wpDir stringByAppendingPathComponent:bgCA];

    WUZip *zip = [WUZip new];
    NSMutableArray<NSString *> *imgNames = [NSMutableArray array];
    for (NSUInteger i = 0; i < frameCount; i++) {
        CGImageRef img = [gen copyCGImageAtTime:CMTimeMakeWithSeconds((double)i / fps, 600) actualTime:NULL error:NULL];
        if (!img) return nil;
        NSData *jpeg = WUJPEGFromCGImage(img, (size_t)(wPt * 3), (size_t)(hPt * 3), 0.5);
        CGImageRelease(img);
        if (!jpeg) return nil;
        NSString *fn = [NSString stringWithFormat:@"f_%04lu.jpg", (unsigned long)i];
        [imgNames addObject:fn];
        [zip addPath:[bgDir stringByAppendingPathComponent:[NSString stringWithFormat:@"assets/%@", fn]] data:jpeg];
    }
    [zip addPath:[bgDir stringByAppendingPathComponent:@"main.caml"]
            data:[WUFramesCaml(wPt, hPt, imgNames, fps) dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[bgDir stringByAppendingPathComponent:@"index.xml"]
            data:[WUIndexXMLDoc() dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[bgDir stringByAppendingPathComponent:@"assetManifest.caml"]
            data:[WUAssetManifestDoc() dataUsingEncoding:NSUTF8StringEncoding]];

    for (NSString *ca in @[flCA, fgCA]) {
        NSString *d = [wpDir stringByAppendingPathComponent:ca];
        [zip addPath:[d stringByAppendingPathComponent:@"main.caml"] data:[WUEmptyCamlDoc() dataUsingEncoding:NSUTF8StringEncoding]];
        [zip addPath:[d stringByAppendingPathComponent:@"index.xml"] data:[WUIndexXMLDoc() dataUsingEncoding:NSUTF8StringEncoding]];
        [zip addPath:[d stringByAppendingPathComponent:@"assetManifest.caml"] data:[WUAssetManifestDoc() dataUsingEncoding:NSUTF8StringEncoding]];
    }

    NSDictionary *wpPlist = @{
        @"appearanceAware": @NO,
        @"assets": @{@"lockAndHome": @{@"default": @{
            @"backgroundAnimationFileName": bgCA,
            @"floatingAnimationFileNameKey": flCA,
            @"foregroundAnimationFileName": fgCA,
            @"identifier": @7400,
            @"name": name,
            @"type": @"LayeredAnimation"}}},
        @"family": @"Custom",
        @"identifier": @7400,
        @"logicalScreenClass": res,
        @"name": name,
        @"version": @1
    };
    [zip addPath:[wpDir stringByAppendingPathComponent:@"Wallpaper.plist"]
            data:[NSPropertyListSerialization dataWithPropertyList:wpPlist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]];

    [zip addPath:[base stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"]
            data:[@"PRPosterRoleLockScreen" dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[base stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
            data:[[[NSUUID UUID].UUIDString uppercaseString] dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[base stringByAppendingPathComponent:@"providerInfo.plist"] data:WUProviderInfo()];
    [zip addPath:[contents stringByAppendingPathComponent:@"com.apple.posterkit.provider.contents.userInfo"]
            data:[NSPropertyListSerialization dataWithPropertyList:@{
                @"posterEnvironmentOverrides": [@"{}" dataUsingEncoding:NSUTF8StringEncoding],
                @"wallpaperRepresentingFileName": wpFolder,
                @"wallpaperRepresentingIdentifier": @"7400"}
                format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]];
    return [zip finish];
}


// ParameterizedCA 包：pca 版
static BOOL WUUseShell(void) {
    id f = WUConfig()[@"format"];
    return ![f isKindOfClass:[NSString class]] || ![f isEqualToString:@"layered"];
}

static BOOL WUUsePCA(void) {
    id f = WUConfig()[@"format"];
    return [f isKindOfClass:[NSString class]] && [(NSString *)f isEqualToString:@"pca"];
}

static NSData *WUBuildPCATendies(NSURL *mediaURL, NSInteger wallpaperID,
                                 double wPt, double hPt, NSUInteger scale,
                                 double fps, CGFloat quality) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mediaURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    if (!asset) return nil;
    double seconds = CMTimeGetSeconds(asset.duration);
    if (!isfinite(seconds) || seconds <= 0) return nil;

    NSUInteger frameCount = (NSUInteger)floor(seconds * fps);
    if (frameCount == 0) frameCount = 1;
    if (frameCount > 60) frameCount = 60;

    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    gen.requestedTimeToleranceBefore = CMTimeMake(1, 5);
    gen.requestedTimeToleranceAfter = CMTimeMake(1, 5);

    size_t pxW = (size_t)(wPt * scale), pxH = (size_t)(hPt * scale);
    NSString *wu = [[NSUUID UUID].UUIDString uppercaseString];
    NSString *did = [[NSUUID UUID].UUIDString uppercaseString];
    NSString *wpName = [NSString stringWithFormat:@"7400.Custom-%gw-%gh@%lux~iphone.wallpaper", wPt, hPt, (unsigned long)scale];
    NSString *base = [NSString stringWithFormat:@"descriptors/%@", wu];
    NSString *v1 = [base stringByAppendingPathComponent:@"versions/1"];
    NSString *contents = [v1 stringByAppendingPathComponent:@"contents"];
    NSString *wpDir = [contents stringByAppendingPathComponent:wpName];
    NSString *caDir = [wpDir stringByAppendingPathComponent:@"wallpaper.ca"];

    WUZip *zip = [WUZip new];

    for (NSUInteger i = 0; i < frameCount; i++) {
        CGImageRef img = [gen copyCGImageAtTime:CMTimeMakeWithSeconds((double)i / fps, 600) actualTime:NULL error:NULL];
        if (!img) return nil;
        NSData *jpeg = WUJPEGFromCGImage(img, pxW, pxH, quality);
        CGImageRelease(img);
        if (!jpeg) return nil;
        [zip addPath:[caDir stringByAppendingPathComponent:[NSString stringWithFormat:@"assets/f_%04lu.jpg", (unsigned long)i]] data:jpeg];
    }

    NSMutableString *vals = [NSMutableString string];
    for (NSUInteger i = 0; i < frameCount; i++) {
        [vals appendFormat:@"                <CGImage src=\"assets/f_%04lu.jpg\"/>\n", (unsigned long)i];
    }
    double duration = (double)frameCount / fps;
    NSString *caml = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
         "<caml xmlns=\"http://www.apple.com/CoreAnimation/1.0\">\n"
         "  <CALayer id=\"__capRootLayer__\" name=\"Root Layer\" bounds=\"0 0 %g %g\" position=\"%g %g\" geometryFlipped=\"0\" opacity=\"1\" transform=\"rotate(0deg)\" backgroundColor=\"0 0 0 1\" cornerRadius=\"0\" allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" cornerCurve=\"circular\">\n"
         "    <sublayers>\n"
         "      <CALayer id=\"background\" name=\"BACKGROUND\" bounds=\"0 0 %g %g\" position=\"%g %g\" geometryFlipped=\"0\" masksToBounds=\"0\" opacity=\"1\" transform=\"rotate(0deg)\" cornerRadius=\"0\" allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" cornerCurve=\"circular\">\n"
         "        <sublayers>\n"
         "          <CALayer id=\"vid\" name=\"video\" bounds=\"0 0 %g %g\" position=\"%g %g\" opacity=\"1\" cornerRadius=\"0\" allowsEdgeAntialiasing=\"1\" allowsGroupOpacity=\"1\" contentsFormat=\"RGBA8\" cornerCurve=\"circular\" caplayKind=\"video\" caplayFrameCount=\"%lu\" caplayFPS=\"%g\" caplayDuration=\"%.6f\" caplayAutoReverses=\"0\" caplayFramePrefix=\"f_\" caplayFrameExtension=\".jpg\" caplaySyncWWithState=\"0\" caplaySyncStateFrameMode=\"{}\">\n"
         "            <contents type=\"CGImage\" src=\"assets/f_0000.jpg\"/>\n"
         "            <animations>\n"
         "              <animation type=\"CAKeyframeAnimation\" calculationMode=\"linear\" keyPath=\"contents\" beginTime=\"1e-100\" duration=\"%.6f\" removedOnCompletion=\"0\" repeatCount=\"inf\" repeatDuration=\"0\" speed=\"1\" timeOffset=\"0\" autoreverses=\"0\">\n"
         "                <values>\n%@                </values>\n"
         "              </animation>\n"
         "            </animations>\n"
         "          </CALayer>\n"
         "        </sublayers>\n"
         "      </CALayer>\n"
         "    </sublayers>\n"
         "  </CALayer>\n</caml>\n",
        wPt, hPt, wPt/2, hPt/2,
        wPt, hPt, wPt/2, hPt/2,
        wPt, hPt, wPt/2, hPt/2,
        (unsigned long)frameCount, fps, duration, duration, vals];
    [zip addPath:[caDir stringByAppendingPathComponent:@"main.caml"] data:[caml dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[caDir stringByAppendingPathComponent:@"assetManifest.caml"]
            data:[WUAssetManifestDoc() dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[caDir stringByAppendingPathComponent:@"index.xml"]
            data:[[NSString stringWithFormat:
                @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                 "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                 "<plist version=\"1.0\">\n<dict>\n"
                 "\t<key>assetManifest</key>\n\t<string>assetManifest.caml</string>\n"
                 "\t<key>documentHeight</key>\n\t<real>%g</real>\n"
                 "\t<key>documentWidth</key>\n\t<real>%g</real>\n"
                 "\t<key>geometryFlipped</key>\n\t<false/>\n"
                 "\t<key>loopEnd</key>\n\t<real>+infinity</real>\n"
                 "\t<key>loopStart</key>\n\t<real>0.0</real>\n"
                 "\t<key>loopingEnabled</key>\n\t<true/>\n"
                 "\t<key>rootDocument</key>\n\t<string>main.caml</string>\n"
                 "\t<key>scalesToFitInPlayer</key>\n\t<true/>\n"
                 "</dict>\n</plist>\n", hPt, wPt] dataUsingEncoding:NSUTF8StringEncoding]];

    NSDictionary *wpPlist = @{
        @"appearanceAware": @NO,
        @"assets": @{@"lockAndHome": @{@"default": @{
            @"assetFileName": @"wallpaper.ca", @"identifier": @7920,
            @"name": @"Custom", @"type": @"ParameterizedCA"}}},
        @"contentVersion": @1.07, @"family": @"Custom", @"identifier": @7920,
        @"logicalScreenClass": @"any", @"name": @"Custom",
        @"preferredProminentColor": @{@"default": @"#FFFFFF"},
        @"preferredTitleColor": @[@"#FFFFFF02"],
        @"version": @6, @"wantsDeviceMotion": @YES
    };
    [zip addPath:[wpDir stringByAppendingPathComponent:@"Wallpaper.plist"]
            data:[NSPropertyListSerialization dataWithPropertyList:wpPlist format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]];

    [zip addPath:[base stringByAppendingPathComponent:@"com.apple.posterkit.role.identifier"]
            data:[@"PRPosterRoleLockScreen" dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[base stringByAppendingPathComponent:@"com.apple.posterkit.provider.descriptor.identifier"]
            data:[did dataUsingEncoding:NSUTF8StringEncoding]];
    [zip addPath:[base stringByAppendingPathComponent:@"providerInfo.plist"] data:WUProviderInfo()];
    return [zip finish];
}

#pragma mark - 调试日志

static NSString *WUWritableDir(void);
static NSArray<NSString *> *WUDirs(void);
static NSDictionary *WUConfig(void);

static void WULog(NSString *fmt, ...) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
    });
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    NSString *path = [WUWritableDir() stringByAppendingPathComponent:@"debug.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}


#pragma mark - 日志浮窗（可分享）

@interface WUPassWindow : UIWindow @end
@implementation WUPassWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFocused { return NO; }
@end

static __weak UIWindow *gWUOverlayWindow;

// App 自己的最上层控制器（跳过我们的浮窗）
static UIViewController *WUPresentVC(void) {
    UIWindow *host = nil;
    NSMutableArray<UIScene *> *scenes = [NSMutableArray array];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) [scenes addObject:sc];
    for (UIScene *sc in scenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w == gWUOverlayWindow || w.isHidden || w.alpha < 0.01) continue;
            if (w.windowLevel > UIWindowLevelAlert) continue;
            host = w;
        }
    }
    UIViewController *vc = host.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

@interface WULogPanel : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIViewController *host;
+ (instancetype)shared;
 - (BOOL)install;
- (void)showMenu;
@end

@implementation WULogPanel

+ (instancetype)shared {
    static WULogPanel *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [WULogPanel new]; });
    return p;
}

- (NSString *)logPath { return [WUWritableDir() stringByAppendingPathComponent:@"debug.log"]; }

- (NSString *)logText {
    NSString *t = [NSString stringWithContentsOfFile:[self logPath] encoding:NSUTF8StringEncoding error:nil];
    return t.length ? t : @"(空)";
}

- (BOOL)install {
    if (self.window) return YES;
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return NO;

    UIWindowScene *scene = nil;
    for (UIScene *sc in app.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)sc; break; }
    }
    if (!scene) return NO;

    WUPassWindow *w = [[WUPassWindow alloc] initWithWindowScene:scene];
    w.windowLevel = UIWindowLevelAlert + 10;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [UIViewController new];
    self.host = w.rootViewController;
    self.host.view.backgroundColor = [UIColor clearColor];
    self.host.view.userInteractionEnabled = YES;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(0, 0, 72, 34);
    btn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    [btn setTitle:@"日志" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    btn.layer.cornerRadius = 8;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.host.view addSubview:btn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [btn addGestureRecognizer:pan];

    CGRect b = scene.coordinateSpace.bounds;
    WULog(@"scene bounds %.0fx%.0f", b.size.width, b.size.height);
    w.frame = CGRectMake(b.size.width - 84, b.size.height * 0.55, 72, 34);
    w.hidden = NO;
    self.window = w;
    gWUOverlayWindow = w;
    WULog(@"overlay installed");
    return YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.superview.window.center = CGPointMake(v.superview.window.center.x + t.x, v.superview.window.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

- (void)showMenu {
    NSString *text = [self logText];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSUInteger start = lines.count > 25 ? lines.count - 25 : 0;
    NSString *tail = [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)] componentsJoinedByString:@"\n"];

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"WalliveUnlock 日志"
                                                               message:tail
                                                        preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [ac addAction:[UIAlertAction actionWithTitle:@"分享日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf share];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"分享原版壁纸包" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [weakSelf shareOriginalPackages];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"复制全部" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = text;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空缓存" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSString *cache = [WUWritableDir() stringByAppendingPathComponent:@"cache"];
        [[NSFileManager defaultManager] removeItemAtPath:cache error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[weakSelf logPath] error:nil];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host = WUPresentVC() ?: self.host;
    [host presentViewController:ac animated:YES completion:nil];
}

// App 自己从服务器下载过的原版包
- (NSArray<NSURL *> *)originalPackages {
    NSMutableArray<NSURL *> *out = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    NSArray *dirs = @[
        [home stringByAppendingPathComponent:@"Library/Application Support/TendiesPackages"],
        [home stringByAppendingPathComponent:@"Library/Application Support/TendiesPackageStore"],
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"tmp"]
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:d error:nil]) {
            if ([[f.pathExtension lowercaseString] isEqualToString:@"tendies"]) {
                [out addObject:[NSURL fileURLWithPath:[d stringByAppendingPathComponent:f]]];
            }
        }
    }
    if (!out.count) {
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:home];
        NSString *rel = nil; int n = 0;
        while ((rel = [en nextObject]) && n < 40000) {
            n++;
            if ([[rel pathExtension].lowercaseString isEqualToString:@"tendies"]) {
                [out addObject:[NSURL fileURLWithPath:[home stringByAppendingPathComponent:rel]]];
                if (out.count >= 20) break;
            }
        }
    }
    return out;
}

- (void)shareOriginalPackages {
    NSArray<NSURL *> *urls = [self originalPackages];
    if (!urls.count) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"没找到原版包"
                                                                   message:@"App 容器里没有 .tendies 文件"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *host = WUPresentVC() ?: self.host;
    [host presentViewController:ac animated:YES completion:nil];
        return;
    }
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.host.view;
        avc.popoverPresentationController.sourceRect = self.host.view.bounds;
    }
    UIViewController *host = WUPresentVC() ?: self.host;
    [host presentViewController:avc animated:YES completion:nil];
}

- (void)share {
    NSURL *url = [NSURL fileURLWithPath:[self logPath]];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.host.view;
        avc.popoverPresentationController.sourceRect = self.host.view.bounds;
    }
    UIViewController *host = WUPresentVC() ?: self.host;
    [host presentViewController:avc animated:YES completion:nil];
}
@end

static void WUInstallLogOverlayAttempt(int attempt) {
    if (![WUConfig()[@"showLogButton"] boolValue]) return;
    if ([[WULogPanel shared] install]) return;
    if (attempt > 30) { WULog(@"overlay install failed"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WUInstallLogOverlayAttempt(attempt + 1);
    });
}

static void WUInstallLogOverlay(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WUInstallLogOverlayAttempt(0);
    });
}

#pragma mark - 目录

static NSArray<NSString *> *WUDirs(void) {
    static NSArray<NSString *> *dirs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        NSString *home = NSHomeDirectory();
        if (home.length) [list addObject:[home stringByAppendingPathComponent:@"Library/WalliveUnlock"]];
        NSString *bundle = [NSBundle mainBundle].bundlePath;
        if (bundle.length) [list addObject:[bundle stringByAppendingPathComponent:@"WalliveUnlock"]];
        [list addObject:@"/var/mobile/Library/WalliveUnlock"];
        [list addObject:@"/var/jb/var/mobile/Library/WalliveUnlock"];
        dirs = list.copy;
    });
    return dirs;
}

static NSString *WUWritableDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *candidate in WUDirs()) {
            [fm createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:nil];
            if ([fm isWritableFileAtPath:candidate]) { dir = candidate; break; }
        }
        if (!dir) dir = WUDirs().firstObject;
    });
    return dir;
}

static NSData *WUReadData(NSString *name) {
    for (NSString *dir in WUDirs()) {
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
        if (data.length) return data;
    }
    return nil;
}

static NSString *WUReadText(NSString *name) {
    for (NSString *dir in WUDirs()) {
        NSString *text = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (text.length) return text;
    }
    return nil;
}

// 模板升级：_v 变化时覆盖 App 容器里的旧模板
static void WUSyncTemplates(void) {
    NSString *writable = WUWritableDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in @[@"access.json", @"download.json"]) {
        NSString *dst = [writable stringByAppendingPathComponent:name];
        NSString *src = nil;
        for (NSString *dir in WUDirs()) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            if (![path isEqualToString:dst] && [fm fileExistsAtPath:path]) { src = path; break; }
        }
        if (!src) continue;

        BOOL copy = ![fm fileExistsAtPath:dst];
        if (!copy) {
            NSString *bundled = [NSString stringWithContentsOfFile:src encoding:NSUTF8StringEncoding error:nil];
            NSString *current = [NSString stringWithContentsOfFile:dst encoding:NSUTF8StringEncoding error:nil];
            if ([bundled containsString:kWUTemplateTag] && ![current containsString:kWUTemplateTag]) copy = YES;
        }
        if (copy) [fm copyItemAtPath:src toPath:dst error:nil];
    }
}

#pragma mark - 配置

static NSDictionary *WUConfig(void) {
    static NSDictionary *cache;
    static NSTimeInterval stamp;
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (cache && (now - stamp) < 2.0) return cache;

    NSData *data = WUReadData(@"config.json");
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

    NSMutableDictionary *cfg = [@{
        @"forgeAccess": @YES,
        @"forgeDownload": @NO,
        @"localFirst": @YES,
        @"rotateDevice": @NO,
        @"showLogButton": @YES,
        @"format": @"layered",
        @"autoRepair": @YES,
        @"downloadTemplate": @"",
        @"downloadMap": @{}
    } mutableCopy];
    if ([json isKindOfClass:[NSDictionary class]]) [cfg addEntriesFromDictionary:json];
    cache = cfg.copy;
    stamp = now;
    return cache;
}

#pragma mark - 模板展开

static NSString *WUExpand(NSString *tpl, NSDictionary<NSString *, NSString *> *vars) {
    NSMutableString *out = [tpl mutableCopy];
    for (NSString *key in vars) {
        [out replaceOccurrencesOfString:[NSString stringWithFormat:@"{{%@}}", key]
                             withString:vars[key]
                                options:0
                                  range:NSMakeRange(0, out.length)];
    }
    return out;
}

static NSString *WUISO8601Now(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });
    return [df stringFromDate:[NSDate date]];
}

static NSString *WUExpireString(void) {
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        df = [NSDateFormatter new];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.timeZone = [NSTimeZone localTimeZone];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    NSDate *expire = [NSDate dateWithTimeIntervalSinceNow:10.0 * 365 * 24 * 3600];
    return [df stringFromDate:expire];
}

static NSString *WUDefaultAccessJSON(void) {
    return @"{\"_v\":6,\"ok\":true,\"server_time\":\"{{NOW_ISO}}\","
           @"\"account\":{\"enabled\":true,\"bound\":true,\"online_allowed\":true},"
           @"\"policy\":{\"daily_limit\":9999,\"weekly_limit\":9999,\"reward_ad_count\":5,"
           @"\"reset_timezone\":\"Asia/Shanghai\",\"reset_weekday\":3,\"membership_enabled\":true,\"ios_ads_enabled\":false},"
           @"\"plans\":[{\"id\":\"monthly\",\"name\":\"月卡\",\"price_cents\":888,\"duration_unit\":\"month\",\"duration_count\":1,\"enabled\":true},"
           @"{\"id\":\"yearly\",\"name\":\"年卡\",\"price_cents\":1088,\"duration_unit\":\"year\",\"duration_count\":1,\"enabled\":true},"
           @"{\"id\":\"lifetime\",\"name\":\"永久会员\",\"price_cents\":1288,\"duration_unit\":\"permanent\",\"duration_count\":0,\"enabled\":true}],"
           @"\"membership\":{\"status\":\"vip\",\"is_permanent\":true,\"vip_expires_at\":\"{{EXPIRES}}\"},"
           @"\"quota\":{\"daily_used\":0,\"daily_reserved\":0,\"daily_remaining\":9999,"
           @"\"daily_next_reset\":\"2099-01-01T00:00:00+08:00\",\"used\":0,\"reserved\":0,\"remaining\":9999,"
           @"\"next_reset\":\"2099-01-01T00:00:00+08:00\",\"completed_ids\":[],\"pending_ids\":[]},"
           @"\"checkout_available\":true}";
}

static NSData *WUAccessPayload(void) {
    NSString *tpl = WUReadText(@"access.json") ?: WUDefaultAccessJSON();
    NSString *text = WUExpand(tpl, @{@"EXPIRES": WUExpireString(), @"NOW_ISO": WUISO8601Now()});
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - 请求解析

static NSString *WUBodyString(NSURLRequest *request) {
    NSData *body = request.HTTPBody;
    if (!body.length) {
        NSInputStream *stream = request.HTTPBodyStream;
        if (stream) {
            [stream open];
            NSMutableData *buf = [NSMutableData data];
            uint8_t chunk[1024];
            while (stream.hasBytesAvailable) {
                NSInteger n = [stream read:chunk maxLength:sizeof(chunk)];
                if (n <= 0) break;
                [buf appendBytes:chunk length:(NSUInteger)n];
            }
            [stream close];
            body = buf;
        }
    }
    if (!body.length) return @"";
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *WUWallpaperID(NSURLRequest *request) {
    NSString *hay = [WUBodyString(request) stringByAppendingFormat:@"&%@", request.URL.query ?: @""];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"(?i)wallpaper[_-]?id[\\\"']?\\s*[:=]\\s*[\\\"']?(\\d+)" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:hay options:0 range:NSMakeRange(0, hay.length)];
    return (m && m.numberOfRanges > 1) ? [hay substringWithRange:[m rangeAtIndex:1]] : @"";
}


#pragma mark - 媒体直链解析（全量分页 + 磁盘缓存）

static NSMutableDictionary<NSString *, NSString *> *gWUMedia;
static NSTimeInterval gWUMediaStamp;
static NSRecursiveLock *gWUMediaLock;

static void WUMediaInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWUMedia = [NSMutableDictionary dictionary];
        gWUMediaLock = [NSRecursiveLock new];
    });
}

static NSString *WUMediaCachePath(void) {
    return [WUWritableDir() stringByAppendingPathComponent:@"media.json"];
}

static void WUMediaLoadFromDisk(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *d = [NSData dataWithContentsOfFile:WUMediaCachePath()];
        if (!d.length) return;
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]]) {
            [gWUMediaLock lock];
            [gWUMedia addEntriesFromDictionary:j];
            [gWUMediaLock unlock];
        }
    });
}

static void WUMediaSaveToDisk(void) {
    [gWUMediaLock lock];
    NSData *d = [NSJSONSerialization dataWithJSONObject:gWUMedia options:0 error:nil];
    [gWUMediaLock unlock];
    if (d.length) [d writeToFile:WUMediaCachePath() atomically:YES];
}

// 单页请求（同步），返回解析后的 data 数组
static NSDictionary *WUFetchPage(NSInteger page) {
    NSURLSessionConfiguration *conf = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    conf.protocolClasses = @[];
    conf.timeoutIntervalForRequest = 12;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:conf];
    NSString *u = [NSString stringWithFormat:@"%@%@?page=%ld", kWUBaseURL, kWUListPath, (long)page];
    __block NSData *result = nil;
    __block BOOL done = NO;
    [[session dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:u]]
          completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) { result = data; done = YES; }] resume];
    NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:12];
    while (!done && [dl timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    [session finishTasksAndInvalidate];
    if (!result.length) return nil;
    id j = [NSJSONSerialization JSONObjectWithData:result options:0 error:nil];
    return [j isKindOfClass:[NSDictionary class]] ? j : nil;
}

static void WUAbsorbPage(NSDictionary *json) {
    id list = json[@"data"];
    if (![list isKindOfClass:[NSArray class]]) return;
    for (id item in list) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id wid = item[@"id"];
        if (!wid) continue;
        NSString *rel = nil;
        id mt = item[@"media_type"];
        if ([mt isKindOfClass:[NSString class]] && [mt isEqualToString:@"video"]) rel = item[@"video_url"];
        if (![rel isKindOfClass:[NSString class]] || !rel.length) rel = item[@"image_url"];
        if (![rel isKindOfClass:[NSString class]] || !rel.length) continue;
        NSString *abs = [rel hasPrefix:@"http"] ? rel : [kWUBaseURL stringByAppendingString:rel];
        [gWUMediaLock lock];
        gWUMedia[[wid description]] = abs;
        [gWUMediaLock unlock];
    }
}

// 全量刷新：page=1.. 直到取满 total
static void WURefreshMediaMap(BOOL force) {
    WUMediaInit();
    WUMediaLoadFromDisk();

    [gWUMediaLock lock];
    NSUInteger have = gWUMedia.count;
    BOOL fresh = !force && have > 10 && (CFAbsoluteTimeGetCurrent() - gWUMediaStamp < 1800.0);
    [gWUMediaLock unlock];
    if (fresh) return;

    NSDictionary *first = WUFetchPage(1);
    if (!first) return;
    [gWUMediaLock lock]; [gWUMedia removeAllObjects]; [gWUMediaLock unlock];
    WUAbsorbPage(first);

    NSInteger total = [first[@"total"] integerValue];
    NSInteger perPage = 10;
    NSInteger pages = total > 0 ? (total + perPage - 1) / perPage : 1;
    if (pages > 80) pages = 80;
    for (NSInteger p = 2; p <= pages; p++) {
        NSDictionary *json = WUFetchPage(p);
        if (!json) break;
        WUAbsorbPage(json);
    }
    [gWUMediaLock lock];
    gWUMediaStamp = CFAbsoluteTimeGetCurrent();
    [gWUMediaLock unlock];
    WUMediaSaveToDisk();
    WULog(@"media map -> %lu items (%ld pages)", (unsigned long)gWUMedia.count, (long)pages);
}

static NSString *WUMediaURLForID(NSString *wallpaperID) {
    if (!wallpaperID.length) return nil;
    WUMediaInit();
    WUMediaLoadFromDisk();
    [gWUMediaLock lock];
    NSString *hit = gWUMedia[wallpaperID];
    [gWUMediaLock unlock];
    if (hit) return hit;

    WURefreshMediaMap(YES);
    [gWUMediaLock lock];
    hit = gWUMedia[wallpaperID];
    [gWUMediaLock unlock];
    return hit;
}

// 本地打包好的 .tendies（随 App 一起分发 / 生成缓存），WalliveUnlock/packages 或 cache
static NSString *WUPackagePath(NSString *wallpaperID) {
    if (!wallpaperID.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *name = [[wallpaperID stringByAppendingString:@"_v18"] stringByAppendingString:@".tendies"];
    NSString *cache = [[WUWritableDir() stringByAppendingPathComponent:@"cache"] stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:cache]) return cache;
    for (NSString *dir in WUDirs()) {
        NSString *p = [[dir stringByAppendingPathComponent:@"packages"] stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:p]) return p;
    }
    return nil;
}

static CGSize WUDevicePixelSize(void) __attribute__((unused));
static CGSize WUDevicePixelSize(void) {
    UIScreen *sc = [UIScreen mainScreen];
    CGSize pt = sc.bounds.size;
    CGFloat scale = sc.scale > 0 ? sc.scale : 3.0;
    CGSize px = CGSizeMake(floor(pt.width * scale), floor(pt.height * scale));
    if (px.width > px.height) { CGFloat t = px.width; px.width = px.height; px.height = t; }
    if (px.width < 640) px = CGSizeMake(1320, 2868);
    return px;
}

static NSString *WUDownURLForID(NSString *wallpaperID, NSString *mediaURL) {
    (void)mediaURL;
    if (wallpaperID.length) {
        return [NSString stringWithFormat:@"%@%@?id=%@", kWUBaseURL, kWUFileDownloadPath, wallpaperID];
    }
    return mediaURL;
}

static NSData *WUDownloadPayloadForURL(NSURLRequest *request, NSString *url) {
    NSString *tpl = WUReadText(@"download.json");
    if (!tpl || !url.length) return nil;
    NSString *wallpaperID = WUWallpaperID(request);
    NSString *text = WUExpand(tpl, @{
        @"DOWN_URL": url,
        @"WALLPAPER_ID": wallpaperID ?: @""
    });
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// 只用本地配置（downloadMap / downloadTemplate），不联网，可安全在主线程调用
static NSData *WUDownloadPayload(NSURLRequest *request) {
    NSString *wallpaperID = WUWallpaperID(request);
    NSDictionary *cfg = WUConfig();

    NSString *url = @"";
    NSDictionary *map = [cfg[@"downloadMap"] isKindOfClass:[NSDictionary class]] ? cfg[@"downloadMap"] : @{};
    if (wallpaperID.length && [map[wallpaperID] isKindOfClass:[NSString class]]) {
        url = map[wallpaperID];
    } else if ([cfg[@"downloadTemplate"] isKindOfClass:[NSString class]] && [cfg[@"downloadTemplate"] length]) {
        url = WUExpand(cfg[@"downloadTemplate"], @{@"WALLPAPER_ID": wallpaperID ?: @""});
    }
    return WUDownloadPayloadForURL(request, url);
}

static NSData *WURepairDownload(NSData *data, NSURLRequest *request) {
    if (!data.length) return data;

    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:[NSMutableDictionary class]]) return data;

    NSMutableDictionary *dict = json;
    NSString *err = [dict[@"error"] isKindOfClass:[NSString class]] ? dict[@"error"] : @"";
    BOOL ok = [dict[@"ok"] boolValue];
    BOOL failed = !ok
        || [err rangeOfString:@"membership" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [err rangeOfString:@"limit" options:NSCaseInsensitiveSearch].location != NSNotFound;
    if (!failed) return data;

    NSData *forged = WUDownloadPayload(request);
    if (!forged) {
        // 配置里没有映射时，用公开列表把 wallpaper_id 解析成媒体直链
        NSString *wid = WUWallpaperID(request);
        forged = WUDownloadPayloadForURL(request, WUDownURLForID(wid, WUMediaURLForID(wid)));
    }
    return forged ?: data;
}

#pragma mark - URLProtocol

@interface WUProtocol : NSURLProtocol
+ (void)installIntoConfiguration:(NSURLSessionConfiguration *)conf;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@end

@implementation WUProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kWUHandledKey inRequest:request]) return NO;
    NSString *path = request.URL.path;
    return [path isEqualToString:kWUAccessPath]
        || [path isEqualToString:kWUDownloadPath]
        || [path isEqualToString:kWUFileDownloadPath];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

+ (void)installIntoConfiguration:(NSURLSessionConfiguration *)conf {
    if (!conf) return;
    NSMutableArray *classes = [conf.protocolClasses mutableCopy] ?: [NSMutableArray array];
    if (![classes containsObject:[self class]]) {
        [classes insertObject:[self class] atIndex:0];
        conf.protocolClasses = classes;
    }
}

- (void)stopLoading {
    [self.task cancel];
    self.task = nil;
}

- (void)startLoading {
    NSString *path = self.request.URL.path;
    NSDictionary *cfg = WUConfig();
    WULog(@"hit %@ id=%@ localFirst=%@", path, WUWallpaperID(self.request), cfg[@"localFirst"]);

    if ([path isEqualToString:kWUAccessPath] && [cfg[@"forgeAccess"] boolValue]) {
        [self deliver:WUAccessPayload()];
        return;
    }
    if ([path isEqualToString:kWUFileDownloadPath]) {
        NSString *wid = WUWallpaperID(self.request);
        if (!wid.length) {
            NSURLComponents *c = [NSURLComponents componentsWithURL:self.request.URL resolvingAgainstBaseURL:NO];
            for (NSURLQueryItem *q in c.queryItems) {
                if ([q.name isEqualToString:@"id"] && q.value.length) { wid = q.value; break; }
            }
        }
        WULog(@"file req id=%@", wid);
        if (!wid.length) { [self deliverStatus:404 body:@"{\"ok\":false,\"error\":\"missing_id\"}"]; return; }
        if (WUPackagePath(wid)) { [self servePackageForID:wid]; return; }
        [self generateAndServePackage:wid];
        return;
    }
    if ([path isEqualToString:kWUDownloadPath]) {
        BOOL localFirst = [cfg[@"localFirst"] boolValue];
        if ([cfg[@"forgeDownload"] boolValue] || localFirst) {
            NSData *payload = WUDownloadPayload(self.request);   // 仅配置，不联网
            if (payload) { [self deliver:payload]; return; }
            if (localFirst) { [self resolveInBackground]; return; }
        }
    }
    [self forward];
}

// 后台把 wallpaper_id 解析成媒体直链，再异步投递；解析失败则回落到真实请求
- (void)resolveInBackground {
    NSURLRequest *request = self.request;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *wid = WUWallpaperID(request);
        NSString *media = WUMediaURLForID(wid);
        WULog(@"resolve id=%@ media=%@", wid, media);
        NSData *payload = WUDownloadPayloadForURL(request, WUDownURLForID(wid, media));
        // 预热：提前开始生成，文件请求到达时可能已就绪
        if (payload && wid.length && !WUPackagePath(wid)) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSString *m = media.length ? media : WUMediaURLForID(wid);
                if (!m.length) return;
                NSURLSessionConfiguration *c2 = [NSURLSessionConfiguration ephemeralSessionConfiguration];
                c2.protocolClasses = @[];
                c2.timeoutIntervalForRequest = 60;
                NSURLSession *s2 = [NSURLSession sessionWithConfiguration:c2];
                __block NSData *mp4 = nil; __block BOOL dn = NO;
                [[s2 dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:m]]
                       completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) { mp4 = d; dn = YES; }] resume];
                NSDate *dl2 = [NSDate dateWithTimeIntervalSinceNow:60];
                while (!dn && [dl2 timeIntervalSinceNow] > 0) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                }
                [s2 finishTasksAndInvalidate];
                if (!mp4.length) return;
                NSString *tmp2 = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"wu_pre_%@.mp4", wid]];
                [mp4 writeToFile:tmp2 atomically:YES];
                NSData *pkg = WUUsePCA() ? WUBuildPCATendies([NSURL fileURLWithPath:tmp2], wid.integerValue, 390, 844, 3, 4.0, 0.45)
                                        : (WUUseShell() ? WUBuildShellTendies([NSURL fileURLWithPath:tmp2], wid.integerValue)
                                                        : WUBuildLayeredTendies([NSURL fileURLWithPath:tmp2], wid.integerValue));
                [[NSFileManager defaultManager] removeItemAtPath:tmp2 error:nil];
                if (pkg.length) {
                    NSString *cd = [WUWritableDir() stringByAppendingPathComponent:@"cache"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:cd withIntermediateDirectories:YES attributes:nil error:nil];
                    [pkg writeToFile:[cd stringByAppendingPathComponent:[[wid stringByAppendingString:@"_v18"] stringByAppendingString:@".tendies"]] atomically:YES];
                    WULog(@"prebuild done id=%@ bytes=%lu", wid, (unsigned long)pkg.length);
                }
            });
        }
        if (payload) {
            [self deliver:payload];
        } else {
            [self forward];
        }
    });
}

- (void)deliverStatus:(NSInteger)code body:(NSString *)text {
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                          statusCode:code
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:@{@"Content-Type": @"application/json",
                                                                       @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]}];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:body];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)generateAndServePackage:(NSString *)wallpaperID {
    NSURLRequest *req = self.request;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *media = WUMediaURLForID(wallpaperID);
        NSData *data = nil;
        if (media.length) {
            NSURLSessionConfiguration *conf = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            conf.protocolClasses = @[];
            conf.timeoutIntervalForRequest = 60;
            NSURLSession *s = [NSURLSession sessionWithConfiguration:conf];
            __block NSData *mp4 = nil;
            __block BOOL done = NO;
            [[s dataTaskWithRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:media]]
                  completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) { mp4 = d; done = YES; }] resume];
            NSDate *dl = [NSDate dateWithTimeIntervalSinceNow:60];
            while (!done && [dl timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
            [s finishTasksAndInvalidate];
            if (mp4.length) {
                NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"wu_%@.mp4", wallpaperID]];
                [mp4 writeToFile:tmp atomically:YES];
                data = WUUsePCA() ? WUBuildPCATendies([NSURL fileURLWithPath:tmp], wallpaperID.integerValue, 390, 844, 3, 4.0, 0.45)
                                  : (WUUseShell() ? WUBuildShellTendies([NSURL fileURLWithPath:tmp], wallpaperID.integerValue)
                                                  : WUBuildLayeredTendies([NSURL fileURLWithPath:tmp], wallpaperID.integerValue));
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
                if (data.length) {
                    NSString *cacheDir = [WUWritableDir() stringByAppendingPathComponent:@"cache"];
                    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
                    [data writeToFile:[cacheDir stringByAppendingPathComponent:
                                       [[wallpaperID stringByAppendingString:@"_v18"] stringByAppendingString:@".tendies"]] atomically:YES];
                }
            }
        }
        if (!data.length) { [self deliverStatus:404 body:@"{\"ok\":false,\"error\":\"package_build_failed\"}"]; return; }
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                           headerFields:@{@"Content-Type": @"application/zip",
                                                                          @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
                                                                          @"Cache-Control": @"no-store"}];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        const NSUInteger chunk = 256 * 1024;
        for (NSUInteger off = 0; off < data.length; off += chunk) {
            @autoreleasepool {
                NSUInteger len = MIN(chunk, data.length - off);
                [self.client URLProtocol:self didLoadData:[data subdataWithRange:NSMakeRange(off, len)]];
            }
        }
        [self.client URLProtocolDidFinishLoading:self];
    });
}

- (void)servePackageForID:(NSString *)wallpaperID {
    NSString *path = WUPackagePath(wallpaperID);
    NSURLRequest *req = self.request;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = path ? [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil] : nil;
        if (!data.length) { [self deliverStatus:404 body:@"{\"ok\":false,\"error\":\"package_missing\"}"]; return; }
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:req.URL
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": @"application/zip",
                                                                           @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
                                                                           @"Cache-Control": @"no-store"}];
        [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        const NSUInteger chunk = 256 * 1024;
        for (NSUInteger off = 0; off < data.length; off += chunk) {
            @autoreleasepool {
                NSUInteger len = MIN(chunk, data.length - off);
                [self.client URLProtocol:self didLoadData:[data subdataWithRange:NSMakeRange(off, len)]];
            }
        }
        [self.client URLProtocolDidFinishLoading:self];
    });
}

- (void)deliver:(NSData *)data {
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                         statusCode:200
                                                        HTTPVersion:@"HTTP/1.1"
                                                       headerFields:@{
                                                           @"Content-Type": @"application/json",
                                                           @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
                                                           @"Cache-Control": @"no-store"
                                                       }];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)forward {
    NSMutableURLRequest *upstream = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kWUHandledKey inRequest:upstream];

    NSURLSessionConfiguration *conf = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    self.session = [NSURLSession sessionWithConfiguration:conf delegate:nil delegateQueue:nil];

    __weak typeof(self) weakSelf = self;
    self.task = [self.session dataTaskWithRequest:upstream
                              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) { [self.client URLProtocol:self didFailWithError:error]; return; }

        NSData *out = data;
        if ([self.request.URL.path isEqualToString:kWUDownloadPath] && [WUConfig()[@"autoRepair"] boolValue]) {
            out = WURepairDownload(data, self.request);
        }

        NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSHTTPURLResponse *final = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                                              statusCode:http ? http.statusCode : 200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:final cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:out ?: [NSData data]];
        [self.client URLProtocolDidFinishLoading:self];
    }];
    [self.task resume];
}

@end

#pragma mark - 设备身份轮换（换新 P-256 身份，尝试拿回免费额度）

static void WURotateDeviceIdentityOnce(void) {
    if (![WUConfig()[@"rotateDevice"] boolValue]) return;
    NSString *marker = [WUWritableDir() stringByAppendingPathComponent:@"rotated.flag"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:marker]) return;

    NSArray<NSDictionary *> *queries = @[
        @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
          (__bridge id)kSecAttrService: @"com.mutually.wallpaper.device"},
        @{(__bridge id)kSecClass: (__bridge id)kSecClassKey,
          (__bridge id)kSecAttrApplicationTag: [@"com.mutually.wallpaper.device" dataUsingEncoding:NSUTF8StringEncoding]}
    ];
    for (NSDictionary *q in queries) SecItemDelete((__bridge CFDictionaryRef)q);
    [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - ATHelper / ATTools 校验绕过

static BOOL WUYes(id self, SEL _cmd) { return YES; }
static BOOL WUNo(id self, SEL _cmd) { return NO; }
static void WUVoid(id self, SEL _cmd) {}

static void WUPatchATTools(void) {
    Class cls = objc_getClass("ATTools");
    if (!cls) return;

    NSArray<NSString *> *yesSels = @[
        @"verifyFlagSignature",
        @"verifyFlagSignatureV2",
        @"verifySignedResponseDictionary:server:",
        @"verifySignedV2ResponseDictionary:server:"
    ];
    NSArray<NSString *> *noSels = @[@"requiresSignedV2Build"];
    NSArray<NSString *> *voidSels = @[
        @"handleRequiredSignedV2ReportFailure",
        @"enterStrictFailureWithMessage:log:",
        @"markRequiredSignedV2NetworkFailure:server:",
        @"markRequiredSignedV2SecurityFailure:server:",
        @"fillStrictFailure:message:",
        @"ensureStrictLocalCheck",
        @"performStrictLocalCheckWithFailure:"
    ];

    for (NSString *sel in yesSels) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(sel));
        if (m) method_setImplementation(m, (IMP)WUYes);
    }
    for (NSString *sel in noSels) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(sel));
        if (m) method_setImplementation(m, (IMP)WUNo);
    }
    for (NSString *sel in voidSels) {
        Method m = class_getInstanceMethod(cls, NSSelectorFromString(sel));
        if (m) method_setImplementation(m, (IMP)WUVoid);
    }
}

static void WUScheduleATToolsPatch(int attempt) {
    if (objc_getClass("ATTools")) { WUPatchATTools(); return; }
    if (attempt > 60) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WUScheduleATToolsPatch(attempt + 1); });
}

#pragma mark - NSURLSession 注入

@implementation NSURLSessionConfiguration (WalliveUnlock)
+ (NSURLSessionConfiguration *)wu_defaultSessionConfiguration {
    NSURLSessionConfiguration *conf = [self wu_defaultSessionConfiguration];
    [WUProtocol installIntoConfiguration:conf];
    return conf;
}
+ (NSURLSessionConfiguration *)wu_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *conf = [self wu_ephemeralSessionConfiguration];
    [WUProtocol installIntoConfiguration:conf];
    return conf;
}
@end

@implementation NSURLSession (WalliveUnlock)
+ (NSURLSession *)wu_sessionWithConfiguration:(NSURLSessionConfiguration *)configuration
                                     delegate:(id)delegate
                                delegateQueue:(NSOperationQueue *)queue {
    [WUProtocol installIntoConfiguration:configuration];
    return [self wu_sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
}
@end

#pragma mark - v2 去广告（GDT 优量汇：开屏/横幅/信息流/激励视频）

// App 侧接了腾讯 GDT（开屏 GDTSplashAd、横幅 GDTUnifiedBannerView、
// 信息流 GDTNativeExpressAdView / GDTUnifiedNativeAdView、激励 GDTRewardVideoAd）
// 和快手 KSAdSDK（激励视频）。思路：所有 GDT 广告的加载/展示入口直接
// 短路——开屏与激励立刻回调失败（App 走“无广告填充”的正常降级路径，
// 开屏秒过、不等待超时），横幅与信息流视图隐藏并归零尺寸（行随之塌缩）。
// 快手激励视频保留（可选观看，不强制；会员已解锁后基本用不到）。

static BOOL WUReplaceMethod(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    method_setImplementation(m, imp);
    return YES;
}

static id WUAdDelegate(id self) {
    id delegate = nil;
    @try { delegate = [self valueForKey:@"delegate"]; } @catch (id e) {}
    return delegate;
}

// ---- 开屏：所有加载/展示入口 → 立刻回调失败 ----
static void WUSplashFail(id self) {
    id delegate = WUAdDelegate(self);
    if (delegate && [delegate respondsToSelector:@selector(splashAdFailToPresent:withError:)]) {
        NSError *err = [NSError errorWithDomain:@"GDTAdSDK" code:1003
                                       userInfo:@{NSLocalizedDescriptionKey: @"no ad fill"}];
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(splashAdFailToPresent:withError:), self, err);
    }
}
static void WUSplashV0(id self, SEL _cmd) { WUSplashFail(self); }
static void WUSplashV1(id self, SEL _cmd, id a) { WUSplashFail(self); }
static void WUSplashV2(id self, SEL _cmd, id a, id b) { WUSplashFail(self); }
static void WUSplashV3(id self, SEL _cmd, id a, id b, id c) { WUSplashFail(self); }

// ---- 横幅：不加载；视图出现即隐藏归零 ----
static void WUBannerV0(id self, SEL _cmd) {}
static BOOL WUBannerIsAdValid(id self, SEL _cmd) { return NO; }
static void WUAdViewDidMoveToWindow(id self, SEL _cmd) {
    @try {
        UIView *v = self;
        v.hidden = YES;
        v.frame = CGRectZero;
    } @catch (id e) {}
}

// ---- 信息流模板：渲染入口 → 立刻回调渲染失败 ----
static void WUNativeRenderFail(id self) {
    id delegate = WUAdDelegate(self);
    if (delegate && [delegate respondsToSelector:@selector(nativeExpressAdViewRenderFail:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(delegate, @selector(nativeExpressAdViewRenderFail:), self);
    }
}
static void WUNativeV0(id self, SEL _cmd) { WUNativeRenderFail(self); }
static BOOL WUNativeIsAdValid(id self, SEL _cmd) { return NO; }

// ---- GDT 激励视频：加载入口 → 立刻回调失败（会员已解锁，无需看广告）----
static void WURewardV0(id self, SEL _cmd) {
    id delegate = WUAdDelegate(self);
    if (delegate && [delegate respondsToSelector:@selector(gdt_rewardVideoAd:didFailWithError:)]) {
        NSError *err = [NSError errorWithDomain:@"GDTAdSDK" code:1003
                                       userInfo:@{NSLocalizedDescriptionKey: @"no ad fill"}];
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(gdt_rewardVideoAd:didFailWithError:), self, err);
    }
}

static void WUInstallAdBlock(void) {
    Class splash = objc_getClass("GDTSplashAd");
    if (splash) {
        WUReplaceMethod(splash, @selector(loadAd), (IMP)WUSplashV0);
        WUReplaceMethod(splash, @selector(loadFullScreenAd), (IMP)WUSplashV0);
        WUReplaceMethod(splash, @selector(loadAdAndShowInWindow:), (IMP)WUSplashV1);
        WUReplaceMethod(splash, @selector(loadAdAndShowInWindow:withBottomView:), (IMP)WUSplashV2);
        WUReplaceMethod(splash, @selector(loadAdAndShowInWindow:withBottomView:skipView:), (IMP)WUSplashV3);
        WUReplaceMethod(splash, @selector(loadAdAndShowFullScreenInWindow:withLogoImage:skipView:), (IMP)WUSplashV3);
        WUReplaceMethod(splash, @selector(showAdInWindow:adProviderView:skipView:), (IMP)WUSplashV3);
        WUReplaceMethod(splash, @selector(showAdInWindow:withBottomView:skipView:), (IMP)WUSplashV3);
        WUReplaceMethod(splash, @selector(showFullScreenAdInWindow:withLogoImage:skipView:), (IMP)WUSplashV3);
    }
    Class banner = objc_getClass("GDTUnifiedBannerView");
    if (banner) {
        WUReplaceMethod(banner, @selector(loadAdAndShow), (IMP)WUBannerV0);
        WUReplaceMethod(banner, @selector(isAdValid), (IMP)WUBannerIsAdValid);
        WUReplaceMethod(banner, @selector(didMoveToWindow), (IMP)WUAdViewDidMoveToWindow);
    }
    Class native = objc_getClass("GDTNativeExpressAdView");
    if (native) {
        WUReplaceMethod(native, @selector(render), (IMP)WUNativeV0);
        WUReplaceMethod(native, @selector(isAdValid), (IMP)WUNativeIsAdValid);
        WUReplaceMethod(native, @selector(isReady), (IMP)WUNativeIsAdValid);
        WUReplaceMethod(native, @selector(didMoveToWindow), (IMP)WUAdViewDidMoveToWindow);
    }
    Class unified = objc_getClass("GDTUnifiedNativeAdView");
    if (unified) {
        WUReplaceMethod(unified, @selector(isAdValid), (IMP)WUNativeIsAdValid);
        WUReplaceMethod(unified, @selector(didMoveToWindow), (IMP)WUAdViewDidMoveToWindow);
    }
    Class reward = objc_getClass("GDTRewardVideoAd");
    if (reward) {
        WUReplaceMethod(reward, @selector(loadAd), (IMP)WURewardV0);
    }
}

#pragma mark - 入口

__attribute__((constructor))
static void WalliveUnlockInit(void) {
    WUInstallAdBlock();

    WUSyncTemplates();
    [NSURLProtocol registerClass:[WUProtocol class]];

    Class confCls = objc_getClass("NSURLSessionConfiguration");
    if (confCls) {
        method_exchangeImplementations(class_getClassMethod(confCls, @selector(defaultSessionConfiguration)),
                                       class_getClassMethod(confCls, @selector(wu_defaultSessionConfiguration)));
        method_exchangeImplementations(class_getClassMethod(confCls, @selector(ephemeralSessionConfiguration)),
                                       class_getClassMethod(confCls, @selector(wu_ephemeralSessionConfiguration)));
    }

    Class sessionCls = objc_getClass("NSURLSession");
    if (sessionCls) {
        method_exchangeImplementations(
            class_getClassMethod(sessionCls, @selector(sessionWithConfiguration:delegate:delegateQueue:)),
            class_getClassMethod(sessionCls, @selector(wu_sessionWithConfiguration:delegate:delegateQueue:)));
    }

    WUScheduleATToolsPatch(0);
    WURotateDeviceIdentityOnce();
    WUInstallLogOverlay();

    // 预热 id -> 媒体直链缓存（后台，失败无副作用）
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        WURefreshMediaMap(NO);
    });
}
