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

#define TWEAK_VERSION "0.4.0"
/* ★ v0.4.0（2026-10-12）：模式门控——真机实测 PVP 一局无限弹/无冷却全开（ArenaCharacterShooter
 *   继承基类 Shoot 被误放行）。修复：my_shoot 每次开火用 il2cpp_object_get_class 查对象类名，
 *   白名单=基类 CharacterShooter（主线/特别行动），子类 Arena/Halloween/Christmas 一律不放行；
 *   my_req/my_rec/my_bal 同受 gInCampaignMode 门控。camp_config.json 的 mode_gate=false 可关掉门控。
 * ★ v0.3.0（2026-10-12）：同步 frida v1.4/v1.5 两个关键修复——
 *   ①refillAmmo 数组偏移 items+0x20 起（旧版 +0x00 读到数组头，无限弹失效根因）
 *   ②my_shoot 补 _coolingDown(0x11C)=false / IsWeaponReady(0x68)=true + 第 5 钩 get_IsWeaponReady→true
 *     （游戏扣扳机先查就绪态，冷却中根本不调 Shoot——必须在源头开闸，frida v1.4 实测教训） */
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
typedef void *(*fn_obj_get_class)(void *);

static fn_domain_get         il2cpp_domain_get;
static fn_thread_attach      il2cpp_thread_attach;
static fn_domain_assemblies  il2cpp_domain_get_assemblies;
static fn_asm_get_image      il2cpp_assembly_get_image;
static fn_img_class_count    il2cpp_image_get_class_count;
static fn_img_get_class      il2cpp_image_get_class;
static fn_class_name         il2cpp_class_get_name;
static fn_class_get_method   il2cpp_class_get_method_from_name;
static fn_obj_get_class      il2cpp_object_get_class;

static BOOL gBound = NO;
static BOOL gReady = NO;         /* ≥1 钩挂上 */
static BOOL gGaveUp = NO;
static BOOL gIdle = NO;          /* master=0 待命（完全不挂钩） */
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
        static BOOL logTrunc = NO;   /* ★ 每次游戏启动只截断一次：日志不跨局堆积（10:14 用户要求） */
        if (!logTrunc) { logTrunc = YES; FILE *t = fopen(gLogPath.fileSystemRepresentation, "w"); if (t) fclose(t); }
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
    BOOL infAmmo;         /* ★ v0.2.0 无限子弹（开火前 currentAmmo=maxAmmo） */
    BOOL noCd;            /* ★ v0.2.0 射击无冷却（_shootCoolDown 归零） */
    BOOL modeGate;        /* ★ v0.4.0 模式门控：只对基类 CharacterShooter（主线/特别行动）生效，
                             子类 Arena=PVP / Halloween / Christmas=活动 一律不放行（真机实测：PVP 一局无限弹全开） */
} CampConfig;

static CampConfig cfg = { YES, YES, YES, YES, YES, YES, YES };

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
        cfg.infAmmo        = JsonBool(j, @"infinite_ammo", YES);
        cfg.noCd           = JsonBool(j, @"no_cooldown", YES);
        cfg.modeGate       = JsonBool(j, @"mode_gate", YES);
    } @catch (NSException *e) { /* 配置坏 = 沿用当前值 */ }
}

static void WriteDefaultConfig(void) {
    @try {
        if ([[NSFileManager defaultManager] fileExistsAtPath:gCfgPath]) return;
        NSString *s = @"{\n"
                      "  \"master\": true,\n"
                      "  \"fix_required\": true,\n"
                      "  \"fix_recommended\": true,\n"
                      "  \"no_ballistics\": true,\n"
                      "  \"infinite_ammo\": true,\n"
                      "  \"no_cooldown\": true,\n"
                      "  \"mode_gate\": true\n"
                      "}\n";
        [s writeToFile:gCfgPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
}

/* ───────────────────────── 三个钩子（替换体读 cfg ⇒ 热开关生效） ───────────────────────── */
static long nReqBlocked = 0, nRecBlocked = 0, nBalForced = 0, nShootRefill = 0;

static BOOL (*orig_req)(void *) = NULL;
static BOOL (*orig_rec)(void *) = NULL;
static BOOL (*orig_bal)(void *) = NULL;
static void (*orig_shoot)(void *) = NULL;
static BOOL (*orig_ready)(void *) = NULL;
static BOOL gInCampaignMode = YES;   /* ★ v0.4.0 模式态：由每次 Shoot 的对象类名刷新（默认 YES=战役优先） */

/* ★ v0.4.0 模式门控：对象类名必须在白名单（基类 CharacterShooter=主线/特别行动）。
 *   子类 ArenaCharacterShooter=PVP / Halloween / Christmas=活动 → NO（真机实测：PVP 一局无限弹全开）。
 *   cfg.modeGate=false = 关闭门控（旧行为，全模式生效） */
static BOOL modeAllowed(void *obj) {
    if (!cfg.modeGate) return YES;
    if (!il2cpp_object_get_class || !il2cpp_class_get_name) return YES;
    void *cls = il2cpp_object_get_class(obj);
    if (!cls) return NO;
    const char *nm = il2cpp_class_get_name(cls);
    if (!nm) return NO;
    return strcmp(nm, "CharacterShooter") == 0;
}

static BOOL my_ready(void *self) {
    if (cfg.noCd && gInCampaignMode) return TRUE;   /* ★ v0.4.0 闸门只在战役系开 */
    return orig_ready(self);
}

/* Profile.get_IsUpgradeRequired（实例方法，x0=this，忽略） */
static BOOL my_req(void *self) {
    if (cfg.master && cfg.fixRequired && gInCampaignMode) { nReqBlocked++; return NO; }
    return orig_req ? orig_req(self) : NO;
}

/* Profile.get_IsUpgradeRecommended（实例方法） */
static BOOL my_rec(void *self) {
    if (cfg.master && cfg.fixRecommended && gInCampaignMode) { nRecBlocked++; return NO; }
    return orig_rec ? orig_rec(self) : NO;
}

/* App.get_DisableBallistics（静态方法，原始实现恒 mov w0,#0 → 关闸时返回 NO 与原行为一致） */
static BOOL my_bal(void *self) {
    if (cfg.master && cfg.noBallistics && gInCampaignMode) { nBalForced++; return YES; }
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
    il2cpp_object_get_class         = (fn_obj_get_class)dlsym(uf, "il2cpp_object_get_class");

    gBound = il2cpp_domain_get && il2cpp_thread_attach &&
             il2cpp_domain_get_assemblies && il2cpp_assembly_get_image &&
             il2cpp_image_get_class_count && il2cpp_image_get_class &&
             il2cpp_class_get_name && il2cpp_class_get_method_from_name &&
             il2cpp_object_get_class;
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

static BOOL hReq = NO, hRec = NO, hBal = NO, hShoot = NO, hReady = NO;

/* ───────────────────────── ★ v0.2.0 无限子弹 + 射击无冷却 ─────────────────────────
 * CharacterShooter（dump 107451）：
 *   +0x94  float _shootCoolDown   —— 每枪冷却时长（WaitCoolDown 协程等它，归零=瞬过）
 *   +0xC8  List<ParamsByCategory> characterShooterParamsByCategory
 *          List+0x10 = items 数组；List+0x18 = 数量；元素+0x18 = currentAmmo(int)；元素+0x1C = maxAmmo(int)
 * 钩 CharacterShooter.Shoot()（开火入口，按名解析，argc=0）：
 *   onEnter：①infAmmo → 开火前把所有类别弹药写满  ②noCd → _shootCoolDown 归零
 *   cfg 钩体内直读 ⇒ camp_config.json 热开关照常生效 */
static void refillAmmo(void *shooter) {
    void *list = *(void **)((char *)shooter + 0xC8);
    if (!list) return;
    void *items = *(void **)((char *)list + 0x10);
    if (!items) return;
    /* ★ v0.3.0 数组偏移修复（对齐 frida v1.5/aim.js 实战口径）：
     *   Il2CppArray 元素从 items+0x20 起（0x10/0x18 是对象头），长度在 items+0x18；
     *   旧版从 items+0x00 起读到数组头当指针 → isNull 全跳过 = 无限弹失效根因 */
    int n = *(int *)((char *)items + 0x18);
    if (n <= 0 || n > 32) return;
    for (int i = 0; i < n; i++) {
        void *it = *(void **)((char *)items + 0x20 + 8 * i);
        if (!it) continue;
        int cap = *(int *)((char *)it + 0x1C);
        if (cap > 0) *(int *)((char *)it + 0x18) = cap;
    }
    nShootRefill++;
}
static void my_shoot(void *self) {
    gInCampaignMode = modeAllowed(self);   /* ★ v0.4.0 每次开火刷新模式态（第一枪即纠正，PVP 第一发也不漏） */
    if (cfg.infAmmo && gInCampaignMode) refillAmmo(self);
    if (cfg.noCd && gInCampaignMode) {
        *(float *)((char *)self + 0x94) = 0.0f;   /* 冷却时长归零 */
        *(char *)((char *)self + 0x11C) = 0;      /* ★ v0.3.0 _coolingDown = false（清已启动的冷却态） */
        *(char *)((char *)self + 0x68) = 1;       /* ★ v0.3.0 IsWeaponReady backing = true */
    }
    orig_shoot(self);
}

/* 幂等：已挂的不重复挂；返回当前已挂总数（0~5） */
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
    if (!hShoot) {
        void *m = findMethodInfo("CharacterShooter", "Shoot", 0);
        if (m) {
            MSHookFunction(*(void **)m, (void *)my_shoot, (void **)&orig_shoot);
            if (orig_shoot) { hShoot = YES; TLog(@"[CAMP] ✅ CharacterShooter.Shoot → 无限弹+无冷却 已挂（cfg 开关热生效）"); }
            else TLog(@"[CAMP] ❌ MSHookFunction(CharacterShooter.Shoot) 失败");
        }
    }
    if (!hReady) {
        void *m = findMethodInfo("CharacterShooter", "get_IsWeaponReady", 0);
        if (m) {
            MSHookFunction(*(void **)m, (void *)my_ready, (void **)&orig_ready);
            if (orig_ready) { hReady = YES; TLog(@"[CAMP] ✅ CharacterShooter.get_IsWeaponReady → true 已挂（扳机闸门恒开，模式门控见 cfg.mode_gate）"); }
            else TLog(@"[CAMP] ❌ MSHookFunction(get_IsWeaponReady) 失败");
        }
    }
    return (hReq ? 1 : 0) + (hRec ? 1 : 0) + (hBal ? 1 : 0) + (hShoot ? 1 : 0) + (hReady ? 1 : 0);
}

/* ───────────────────────── 心跳 + 配置热载 ───────────────────────── */
static void startTimers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            static long hb = 0;
            hb++;
            if (hb % 10 == 0) {
                TLog(@"[心跳] 进程活着  req拦=%ld  rec拦=%ld  弹道闸=%ld  开火补弹=%ld  ready=%d gaveUp=%d",
                     nReqBlocked, nRecBlocked, nBalForced, nShootRefill, (int)gReady, (int)gGaveUp);
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
    if (gGaveUp && !gIdle) return;
    @try {
        /* ★ master=0 = 真不挂钩：MSHook 一个都不装，热开配置后 5 秒内自动装上 */
        if (!cfg.master) {
            if (!gIdle) {
                gIdle = YES;
                gGaveUp = NO;           /* 待命结束后来一轮新装配 */
                TLog(@"[CAMP] master=0 —— 不挂钩待命中（把 camp_config.json 的 master 改 true，5 秒内热装）");
            }
            scheduleRetry();
            return;
        }
        if (gIdle) {                    /* 待命 → 激活：重置装配状态 */
            gIdle = NO;
            gAttempts = 0;
            gImgN = 0;
            TLog(@"[CAMP] master=true —— 开始挂钩装配");
        }
        gAttempts++;
        if (!gBound && !bindIl2cpp()) { scheduleRetry(); return; }

        void *dom = il2cpp_domain_get();
        if (!dom) { scheduleRetry(); return; }
        il2cpp_thread_attach(dom);   /* 主线程挂运行时线程，解析才安全（PVEGA 同款） */

        if (gImgN == 0 && !collectImages()) { scheduleRetry(); return; }

        if (gAttempts == 1 || gAttempts % 10 == 0)
            TLog(@"[CAMP] 第 %d 次装配：image=%d", gAttempts, gImgN);

        int total = installHooks();
        if (total >= 5) {
            gReady = YES;
            TLog(@"[CAMP][LOADED] SniperCAMP v%s —— 5/5 钩就位（进任务两钩 + 弹道闸 + 无限弹/无冷却/扳机闸门）", TWEAK_VERSION);
            startTimers();
            return;
        }
        if (gAttempts >= MAX_ATTEMPTS) {
            gGaveUp = YES;
            TLog(@"[CAMP] ❌ %d 次后仍缺钩：req=%d rec=%d bal=%d shoot=%d ready=%d —— 停止重试（游戏版本类名变了？）",
                 gAttempts, (int)hReq, (int)hRec, (int)hBal, (int)hShoot, (int)hReady);
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
        TLog(@"[CAMP] 配置: master=%d fix_required=%d fix_recommended=%d no_ballistics=%d infinite_ammo=%d no_cooldown=%d mode_gate=%d (%@)",
             (int)cfg.master, (int)cfg.fixRequired, (int)cfg.fixRecommended, (int)cfg.noBallistics, (int)cfg.infAmmo, (int)cfg.noCd, (int)cfg.modeGate, gCfgPath);

        startTimers();   /* 心跳+配置热载立即开跑（master=0 待命时也照常） */
        dispatch_async(dispatch_get_main_queue(), ^{ setupStep(); });
    }
}
