/*
 * IntentsHelperQuiet v1.0.0
 *
 * 目标：intents_helper 只做一件事——砍掉「全量扫描」，其它一律放行。
 *
 * 背景（2026-11-22 实锤）：
 *   把 intents_helper.xpc 用 bindfs 挂空后，微信视频来电必崩。
 *   崩溃栈：INImageServiceConnection storeImage: (同步 XPC) -> 等 30s ->
 *   serviceExtensionTimeWillExpire -> 解引用 0x10 -> SIGSEGV。
 *   结论：图片/头像存取是微信、Soul 等 App 通知扩展的生命线，绝对不能动。
 *
 * 本版策略（只拦扫描，不碰图片）：
 *   拦：loadSchemaURLsWithCompletion: / loadSchemaURLsForBundleIdentifiers:completion:
 *       / loadBundleURLsForBundleIdentifiers:completion: / intentDefinitionURLs(ForBundleID:)
 *       / purgeExpiredImagesInEphemeralStore / fetchShareExtensionIntent...（可关）
 *   保留（完全不 hook）：
 *       storeImage:scaled:qualityOfService:storeType:completion:
 *       retrieveImageWithIdentifier:completion:
 *       loadDataImageForImage:scaledWidth:scaledHeight:usingPortableImageLoader:completion:
 *       purgeImageWithIdentifier:completion:
 *       storeUserContext:forBundleIdentifier:
 *
 * 实现纪律：
 *   - 纯 objc runtime（class_getInstanceMethod + method_setImplementation），
 *     不链接 substrate/ellekit/Foundation/UIKit，避免 launchd XPC 服务
 *     dlopen 重框架而静默失败（Probe 已验证的同一纪律）。
 *   - 被拦方法「不调用原实现、不保存原 IMP」=> 天然规避 arm64e 上
 *     ptrauth 二次签名导致的 blraaz 认证失败崩溃（CacheDeleteQuiet v1.2.0 的坑）。
 *   - completion 一律按 2 参数 (result, error) 调用：多传参数在 arm64 调用
 *     约定下无害，少传才会让调用方拿到野指针。
 *
 * 日志：进程自有目录 /var/mobile/Library/Intents/ihq_<pid>.log（SSH 加
 *   /rootfs/private 头读取），fallback /var/tmp/ihq_<pid>.log。
 *
 * flag（touch 后重开 App / kickstart 生效）：
 *   DISABLED              完全不装 hook（等于未装）
 *   PASSTHROUGH_ALL       同 DISABLED
 *   KEEP_SHARE            保留分享建议（PeopleSuggester 那条不拦）
 *   KEEP_SCHEMA_GETTERS   保留 intentDefinitionURLs 两个 getter
 */

#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>

/* ---------------- flags ---------------- */
#define IHQ_FLAG_DIR0 "/var/mobile/Library/Intents/IntentsHelperQuiet"
#define IHQ_FLAG_DIR1 "/var/tmp/IntentsHelperQuiet"

/* ---------------- log ---------------- */
#define IHQ_LOG_DIR   "/var/mobile/Library/Intents"
#define IHQ_LOG_PATH  IHQ_LOG_DIR "/ihq_%d.log"
#define IHQ_LOG_PATH2 "/var/tmp/ihq_%d.log"

static int  g_logfd = -1;
static char g_logpath[224] = "(none)";

static int  g_block_schema  = 1;
static int  g_block_share   = 1;
static int  g_keep_getters  = 0;

static void ihq_append(const char *b, size_t n) {
    if (g_logfd < 0) return;
    (void)!write(g_logfd, b, n);
}
static void ihq_line(const char *fmt, ...) {
    char b[768];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    if (n > 0) ihq_append(b, (size_t)n < sizeof b ? (size_t)n : sizeof b - 1);
}
static void ihq_open_log(void) {
    char p0[256], p2[256];
    snprintf(p0, sizeof p0, IHQ_LOG_PATH,  (int)getpid());
    snprintf(p2, sizeof p2, IHQ_LOG_PATH2, (int)getpid());
    (void)mkdir(IHQ_LOG_DIR, 0755);
    int fd = open(p0, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { g_logfd = fd; strncpy(g_logpath, p0, sizeof g_logpath - 1); return; }
    fd = open(p2, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { g_logfd = fd; strncpy(g_logpath, p2, sizeof g_logpath - 1); return; }
}

static int ihq_flag(const char *name) {
    char p[352];
    snprintf(p, sizeof p, IHQ_FLAG_DIR0 "/%s", name);
    if (access(p, F_OK) == 0) return 1;
    snprintf(p, sizeof p, IHQ_FLAG_DIR1 "/%s", name);
    return access(p, F_OK) == 0;
}

/* ---------------- 空对象 / completion 调用 ---------------- */
static id ihq_empty_dict(void) {
    Class c = objc_getClass("NSDictionary");
    return c ? ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("dictionary")) : (id)0;
}
static id ihq_empty_array(void) {
    Class c = objc_getClass("NSArray");
    return c ? ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("array")) : (id)0;
}

/* 统一 2 参数调用 (result, error)；少传参数会让调用方拿到野指针。 */
static void ihq_cb(id blk, id a, id b) {
    if (!blk) return;
    void (^cb)(id, id) = (void (^)(id, id))blk;
    cb(a, b);
}

/* ---------------- 计数限流 ---------------- */
static long g_c_schema_all = 0, g_c_schema_ids = 0, g_c_bundle_urls = 0;
static long g_c_purge_exp  = 0, g_c_share = 0, g_c_getters = 0;

static void ihq_count(const char *tag, long *ctr) {
    long n = __sync_add_and_fetch(ctr, 1);
    if (n <= 5 || (n % 100) == 0) ihq_line("BLOCK %s #%ld", tag, n);
}

/* ---------------- 被拦实现 ----------------
 * 签名统一带 self/_cmd；completion 走 ihq_cb 两参调用。 */
static void q_schema_all(id self, SEL _cmd, id completion) {
    (void)self; (void)_cmd;
    ihq_count("loadSchemaURLsWithCompletion:", &g_c_schema_all);
    ihq_cb(completion, ihq_empty_dict(), (id)0);
}
static void q_schema_ids(id self, SEL _cmd, id ids, id completion) {
    (void)self; (void)_cmd; (void)ids;
    ihq_count("loadSchemaURLsForBundleIdentifiers:", &g_c_schema_ids);
    ihq_cb(completion, ihq_empty_dict(), (id)0);
}
static void q_bundle_urls(id self, SEL _cmd, id ids, id completion) {
    (void)self; (void)_cmd; (void)ids;
    ihq_count("loadBundleURLsForBundleIdentifiers:", &g_c_bundle_urls);
    ihq_cb(completion, ihq_empty_dict(), (id)0);
}
static void q_purge_expired(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    ihq_count("purgeExpiredImagesInEphemeralStore", &g_c_purge_exp);
    /* 直接返回：不再扫 Library/Intents/Images 里 600+ 个目录。不删图、不动缓存。 */
}
static void q_share(id self, SEL _cmd, id uuid, id completion) {
    (void)self; (void)_cmd; (void)uuid;
    ihq_count("fetchShareExtensionIntent", &g_c_share);
    ihq_cb(completion, (id)0, (id)0);
}
static id q_def_urls(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    ihq_count("intentDefinitionURLs", &g_c_getters);
    return ihq_empty_array();
}
static id q_def_urls_bid(id self, SEL _cmd, id bid) {
    (void)self; (void)_cmd; (void)bid;
    ihq_count("intentDefinitionURLsForBundleID:", &g_c_getters);
    return ihq_empty_array();
}

/* ---------------- 安装 ---------------- */
static int ihq_hook(Class cls, const char *selname, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel_registerName(selname));
    if (!m) { ihq_line("MISS %s", selname); return 0; }
    method_setImplementation(m, imp);
    ihq_line("HOOK %s", selname);
    return 1;
}

static void ihq_install(void) {
    Class cls = objc_getClass("INHService");
    if (!cls) { ihq_line("WARN class INHService not visible"); return; }

    if (g_block_schema) {
        ihq_hook(cls, "loadSchemaURLsWithCompletion:", (IMP)q_schema_all);
        ihq_hook(cls, "loadSchemaURLsForBundleIdentifiers:completion:", (IMP)q_schema_ids);
        ihq_hook(cls, "loadBundleURLsForBundleIdentifiers:completion:", (IMP)q_bundle_urls);
        if (!g_keep_getters) {
            ihq_hook(cls, "intentDefinitionURLs", (IMP)q_def_urls);
            ihq_hook(cls, "intentDefinitionURLsForBundleID:", (IMP)q_def_urls_bid);
        }
    }
    ihq_hook(cls, "purgeExpiredImagesInEphemeralStore", (IMP)q_purge_expired);
    if (g_block_share) {
        ihq_hook(cls, "fetchShareExtensionIntentForExtensionContextUUID:completion:", (IMP)q_share);
    }
    ihq_line("INSTALL DONE  images/avatars PRESERVED "
             "(storeImage/retrieveImage/loadDataImage/purgeImage/storeUserContext untouched)");
}

static void *ihq_wait_install(void *arg) {
    (void)arg;
    for (int i = 0; i < 120; i++) {
        if (objc_getClass("INHService")) { ihq_install(); return NULL; }
        usleep(250000);
    }
    ihq_line("GIVEUP INHService not visible after 30s");
    return NULL;
}

__attribute__((constructor)) static void ihq_init(void) {
    ihq_open_log();
    ihq_line("BOOT v1.0.0 pid=%d log=%s", (int)getpid(), g_logpath);

    if (ihq_flag("DISABLED") || ihq_flag("PASSTHROUGH_ALL")) {
        ihq_line("FLAG %s -> hooks NOT installed",
                 ihq_flag("DISABLED") ? "DISABLED" : "PASSTHROUGH_ALL");
        return;
    }
    if (ihq_flag("KEEP_SHARE"))          g_block_share  = 0;
    if (ihq_flag("KEEP_SCHEMA_GETTERS")) g_keep_getters = 1;
    ihq_line("CONFIG blockSchema=%d blockShare=%d keepGetters=%d",
             g_block_schema, g_block_share, g_keep_getters);

    if (objc_getClass("INHService")) { ihq_install(); return; }

    pthread_t t;
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&t, &a, ihq_wait_install, NULL) != 0)
        ihq_line("ERROR pthread_create errno=%d", errno);
    pthread_attr_destroy(&a);
}
