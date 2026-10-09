/* ============================================================================
 * SniperCAMP — Sniper3D【主线+特别行动】tweak（campaign_min.js 3 钩定稿版的原生移植）
 * 注入方式：Dopamine 运行时注入（不动磁盘二进制，TNG 已验证的路线）
 *
 * ★ v0.1.0：三个 IL2CPP bool getter，全部【按名运行时解析】（零硬编码地址，跨小版本稳）：
 *   1) Profile.get_IsUpgradeRequired     → false （ContinueStartMission@0x36E09F4
 *      拦截链的真正总闸，反汇编实锤：true → ShowUpgradeRequired 弹窗挡进任务）
 *   2) Profile.get_IsUpgradeRecommended  → false （推荐弹窗一并拦掉）
 *   3) App.get_DisableBallistics         → true  （官方弹道总闸，0x3429508 原始实现
 *      就是 mov w0,#0 的硬编码开关。LevelController.get_UseBallistics =
 *      _useBallistics && !DisableBallistics ⇒ 开 true = 子弹下坠消失；
 *      LevelController.get_Wind 新旧两路径（_wind@0xC0/_ABWind@0xC4）末尾都查
 *      该闸，true 直接返回 0.0 ⇒ 开 true = 风向归零）
 *
 * ★ 移植铁律（campaign_min.js 血泪教训）：就这 3 个钩。无定时器写入、无网格钩子、
 *   无清零、无按钮强写 —— JS 版 3 钩真机验证"进任务+结算+去风向下坠"稳定，
 *   任何附加钩子都可能踩中任务生命周期点的原生反作弊 SIGKILL。
 *
 * 设计要点：
 *   - 类按名查找 = 扫全部 image 找"类名匹配 且 目标方法存在"的类（同名歧义按方法存在性消歧）
 *   - 钩体内每调用读一次 cfg ⇒ camp_config.json 改完 5 秒内热生效（关掉某开关 = 回原行为）
 *   - 计数器 + 心跳日志：看 camp_tweak.log 就知道每个闸有没有在拦
 * ========================================================================== */

#import <Foundation/Foundation.h>
#import <substrate.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdarg.h>

#define TWEAK_VERSION "0.1.0"
#define BUNDLE_SNIPER3D_NS @"com.fungames.sniper3d"   /* NSString 版（isEqualToString 用） */
#define CFG_BASE  "camp_config"
#define LOG_NAME  "camp_tweak.log"
#define MAX_ATTEMPTS 60          /* 600ms × 60 ≈ 36 秒还挂不上就放弃重试 */
#define RETRY_INTERVAL_MS 600

/* ───────────────────────── il2cpp API（dlsym 按名绑定） ───────────────────────── */
typedef void *(*fn_domain_get)(void);
typedef void *(*fn_thread_attach)(void *);
typedef void *(*fn_domain_assemblies)(void *, size_t *);
typedef void *(*fn_asm_get_image)(void *);
typedef size_t (*fn_img_class_count)(void *);
typedef void *(*fn_img_get_class)(void *, size_t);
typedef const char *(*fn_class_name)(void *);
typedef void *(*fn_class_get_method)(void *, const char *, int);

static fn_domain_get         il2cpp_domain_get;
static fn_thread_attach      il2cpp_thread_attach;
static fn_domain_assemblies  il2cpp_domain_get_assemblies;
static fn_asm_get_image      il2cpp_assembly_get_image;
static fn_img_class_count    il2cpp_image_get_class_count;
static fn_img_get_class      il2cpp_image_get_class;
static fn_class_name         il2cpp_class_get_name;
static fn_class_get_method   il2cpp_class_get_method_from_name;

static BOOL gBound = NO;
static BOOL gReady = NO;         /* ≥1 钩挂上 */
static BOOL gGaveUp = NO;
static int  gAttempts = 0;
static void *gImgs[128];         /* il2cpp image 指针缓存 */
static int   gImgN = 0;

static NSString *gLogPath = nil;
static NSString *gCfgPath = nil;

/* ───────────────────────── 日志 ───────────────────────── */
static void TLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void TLog(NSString *fmt, ...) {
    if (gLogPath.length == 0) return;
    @try {
        static NSLock *lk = nil;
        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            lk = [[NSLock alloc] init];
            df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"HH:mm:ss";
        });
        va_list ap;
        va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], s];
        [lk lock];
        FILE *f = fopen(gLogPath.fileSystemRepresentation, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
        [lk unlock];
    } @catch (NSException *e) { /* 日志永不炸进程 */ }
}

/* ───────────────────────── 配置（热载） ───────────────────────── */
typedef struct {
    BOOL master;          /* 总开关 */
    BOOL fixRequired;     /* Profile.get_IsUpgradeRequired → false */
    BOOL fixRecommended;  /* Profile.get_IsUpgradeRecommended → false */
    BOOL noBallistics;    /* App.get_DisableBallistics → true（去下坠+风向） */
} CampConfig;

static CampConfig cfg = { YES, YES, YES, YES };

static BOOL JsonBool(NSDictionary *j, NSString *key, BOOL dflt) {
    id v = j[key];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return dflt;
}

static void LoadConfig(void) {
    @try {
        NSData *d = [NSData dataWithContentsOfFile:gCfgPath];
        if (!d) return;
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if (![j isKindOfClass:[NSDictionary class]]) return;
        cfg.master         = JsonBool(j, @"master", YES);
        cfg.fixRequired    = JsonBool(j, @"fix_required", YES);
        cfg.fixRecommended = JsonBool(j, @"fix_recommended", YES);
        cfg.noBallistics   = JsonBool(j, @"no_ballistics", YES);
    } @catch (NSException *e) { /* 配置坏 = 沿用当前值 */ }
}

static void WriteDefaultConfig(void) {
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:gCfgPath]) return;
        NSString *s = @"{\n"
                      "  \"master\": true,\n"
                      "  \"fix_required\": true,\n"
                      "  \"fix_recommended\": true,\n"
                      "  \"no_ballistics\": true\n"
                      "}\n";
        [s writeToFile:gCfgPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
}

/* ───────────────────────── 三个钩子（替换体读 cfg ⇒ 热开关生效） ───────────────────────── */
static long nReqBlocked = 0, nRecBlocked = 0, nBalForced = 0;

static BOOL (*orig_req)(void *) = NULL;
static BOOL (*orig_rec)(void *) = NULL;
static BOOL (*orig_bal)(void *) = NULL;

/* Profile.get_IsUpgradeRequired（实例方法，x0=this，忽略） */
static BOOL my_req(void *self) {
    if (cfg.master && cfg.fixRequired) { nReqBlocked++; return NO; }
    return orig_req ? orig_req(self) : NO;
}

/* Profile.get_IsUpgradeRecommended（实例方法） */
static BOOL my_rec(void *self) {
    if (cfg.master && cfg.fixRecommended) { nRecBlocked++; return NO; }
    return orig_rec ? orig_rec(self) : NO;
}

/* App.get_DisableBallistics（静态方法，原始实现恒 mov w0,#0 → 关闸时返回 NO 与原行为一致） */
static BOOL my_bal(void *self) {
    if (cfg.master && cfg.noBallistics) { nBalForced++; return YES; }
    return orig_bal ? orig_bal(self) : NO;
}

/* ───────────────────────── il2cpp 绑定 + 按名解析 ───────────────────────── */
static BOOL bindIl2cpp(void) {
    void *uf = NULL;
    for (uint32_t i = _dyld_image_count(); i > 0; i--) {
        const char *nm = _dyld_get_image_name(i - 1);
        if (nm && strstr(nm, "UnityFramework") != NULL) {
            uf = dlopen(nm, RTLD_LAZY | RTLD_NOLOAD);
            break;
        }
    }
    if (!uf) return NO;

    il2cpp_domain_get              = (fn_domain_get)dlsym(uf, "il2cpp_domain_get");
    il2cpp_thread_attach           = (fn_thread_attach)dlsym(uf, "il2cpp_thread_attach");
    il2cpp_domain_get_assemblies   = (fn_domain_assemblies)dlsym(uf, "il2cpp_domain_get_assemblies");
    il2cpp_assembly_get_image      = (fn_asm_get_image)dlsym(uf, "il2cpp_assembly_get_image");
    il2cpp_image_get_class_count   = (fn_img_class_count)dlsym(uf, "il2cpp_image_get_class_count");
    il2cpp_image_get_class         = (fn_img_get_class)dlsym(uf, "il2cpp_image_get_class");
    il2cpp_class_get_name          = (fn_class_name)dlsym(uf, "il2cpp_class_get_name");
    il2cpp_class_get_method_from_name = (fn_class_get_method)dlsym(uf, "il2cpp_class_get_method_from_name");

    gBound = il2cpp_domain_get && il2cpp_thread_attach &&
             il2cpp_domain_get_assemblies && il2cpp_assembly_get_image &&
             il2cpp_image_get_class_count && il2cpp_image_get_class &&
             il2cpp_class_get_name && il2cpp_class_get_method_from_name;
    if (!gBound) TLog(@"[CAMP] il2cpp 导出不齐（缺符号），下一轮重试");
    return gBound;
}

static BOOL collectImages(void) {
    void *dom = il2cpp_domain_get();
    if (!dom) return NO;
    size_t n = 0;
    void **arr = (void **)il2cpp_domain_get_assemblies(dom, &n);
    if (!arr || n == 0) return NO;
    int cnt = 0;
    for (size_t i = 0; i < n && cnt < 128; i++) {
        void *im = il2cpp_assembly_get_image(arr[i]);
        if (im) gImgs[cnt++] = im;
    }
    gImgN = cnt;
    return cnt > 0;
}

/* 扫全部 image：类名匹配 且 目标方法存在且 methodPointer 非空 → 返回 MethodInfo*
 * （同名类歧义按"有没有这个方法"消歧；返回的指针直接给 MSHookFunction 解引用） */
static void *findMethodInfo(const char *clsName, const char *methName, int argc) {
    if (!gBound || gImgN == 0) return NULL;
    for (int i = 0; i < gImgN; i++) {
        size_t cc = 0;
        @try { cc = il2cpp_image_get_class_count(gImgs[i]); } @catch (NSException *e) { continue; }
        for (size_t j = 0; j < cc; j++) {
            void *cls = NULL;
            @try { cls = il2cpp_image_get_class(gImgs[i], j); } @catch (NSException *e) { continue; }
            if (!cls) continue;
            const char *cn = il2cpp_class_get_name(cls);
            if (!cn || strcmp(cn, clsName) != 0) continue;
            void *m = il2cpp_class_get_method_from_name(cls, methName, argc);
            if (m && *(void **)m) return m;
        }
    }
    return NULL;
}

static BOOL hReq = NO, hRec = NO, hBal = NO;

/* 幂等：已挂的不重复挂；返回当前已挂总数（0~3） */
static int installHooks(void) {
    if (!hReq) {
        void *m = findMethodInfo("Profile", "get_IsUpgradeRequired", 0);
        if (m) {
            MSHookFunction(*(void **)m, (void *)my_req, (void **)&orig_req);
            if (orig_req) { hReq = YES; TLog(@"[CAMP] ✅ Profile.get_IsUpgradeRequired → false 已挂"); }
            else TLog(@"[CAMP] ❌ MSHookFunction(get_IsUpgradeRequired) 失败");
        }
    }
    if (!hRec) {
        void *m = findMethodInfo("Profile", "get_IsUpgradeRecommended", 0);
        if (m) {
            MSHookFunction(*(void **)m, (void *)my_rec, (void **)&orig_rec);
            if (orig_rec) { hRec = YES; TLog(@"[CAMP] ✅ Profile.get_IsUpgradeRecommended → false 已挂"); }
            else TLog(@"[CAMP] ❌ MSHookFunction(get_IsUpgradeRecommended) 失败");
        }
    }
    if (!hBal) {
        void *m = findMethodInfo("App", "get_DisableBallistics", 0);
        if (m) {
            MSHookFunction(*(void **)m, (void *)my_bal, (void **)&orig_bal);
            if (orig_bal) { hBal = YES; TLog(@"[CAMP] ✅ App.get_DisableBallistics → true 已挂（去下坠+风向）"); }
            else TLog(@"[CAMP] ❌ MSHookFunction(get_DisableBallistics) 失败");
        }
    }
    return (hReq ? 1 : 0) + (hRec ? 1 : 0) + (hBal ? 1 : 0);
}

/* ───────────────────────── 心跳 + 配置热载 ───────────────────────── */
static void startTimers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            static long hb = 0;
            hb++;
            if (hb % 10 == 0) {
                TLog(@"[心跳] 进程活着  req拦=%ld  rec拦=%ld  弹道闸=%ld  ready=%d gaveUp=%d",
                     nReqBlocked, nRecBlocked, nBalForced, (int)gReady, (int)gGaveUp);
            }
        }];
        [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *t) {
            LoadConfig();   /* 钩体内读 cfg ⇒ 热开关立即生效 */
        }];
    });
}

/* ───────────────────────── 装配重试 ───────────────────────── */
static void setupStep(void);

static void scheduleRetry(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)RETRY_INTERVAL_MS * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ setupStep(); });
}

static void setupStep(void) {
    if (gGaveUp) return;
    @try {
        gAttempts++;
        if (!gBound && !bindIl2cpp()) { scheduleRetry(); return; }

        void *dom = il2cpp_domain_get();
        if (!dom) { scheduleRetry(); return; }
        il2cpp_thread_attach(dom);   /* 主线程挂运行时线程，解析才安全（PVEGA 同款） */

        if (gImgN == 0 && !collectImages()) { scheduleRetry(); return; }

        if (gAttempts == 1 || gAttempts % 10 == 0)
            TLog(@"[CAMP] 第 %d 次装配：image=%d", gAttempts, gImgN);

        int total = installHooks();
        if (total == 3) {
            gReady = YES;
            TLog(@"[CAMP][LOADED] SniperCAMP v%s —— 3/3 钩就位（进任务两钩 + 弹道总闸一钩）", TWEAK_VERSION);
            startTimers();
            return;
        }
        if (gAttempts >= MAX_ATTEMPTS) {
            gGaveUp = YES;
            TLog(@"[CAMP] ❌ %d 次后仍缺钩：req=%d rec=%d bal=%d —— 停止重试（游戏版本类名变了？）",
                 gAttempts, (int)hReq, (int)hRec, (int)hBal);
            startTimers();
            return;
        }
        gImgN = 0;   /* 强制下轮重扫（游戏启动早期 assembly 可能还没全载入） */
        scheduleRetry();
    } @catch (NSException *e) {
        TLog(@"[CAMP] setup 异常: %@ —— 重试", e);
        gImgN = 0;
        scheduleRetry();
    }
}

/* ───────────────────────── 入口 ───────────────────────── */
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:BUNDLE_SNIPER3D_NS]) return;

        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (doc.length == 0) return;
        gLogPath = [doc stringByAppendingPathComponent:@LOG_NAME];
        gCfgPath = [doc stringByAppendingPathComponent:@CFG_BASE @".json"];

        WriteDefaultConfig();
        LoadConfig();
        TLog(@"================== SniperCAMP v%s 注入（bundle=%@）==================",
             TWEAK_VERSION, bid);
        TLog(@"[CAMP] 配置: master=%d fix_required=%d fix_recommended=%d no_ballistics=%d (%@)",
             (int)cfg.master, (int)cfg.fixRequired, (int)cfg.fixRecommended, (int)cfg.noBallistics, gCfgPath);

        dispatch_async(dispatch_get_main_queue(), ^{ setupStep(); });
    }
}
