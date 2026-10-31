// language: ObjC++, file: Tweak.mm, target: iOS 14+ ARM64, Theos + CydiaSubstrate
// hooks UnityEngine game loop, draws ESP overlay, applies aimbot on ADS

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <substrate.h>
#include <mach-o/dyld.h>
#include <cmath>
#include <vector>
#include <string>

// ── Offsets (Free Fire ~OB47 ARM64 — re-derive per patch) ──────────────────
// base = sliding image base: _dyld_get_image_vmaddr_slide(idx) for libil2cpp
// derive with: frida> Module.findBaseAddress("libil2cpp.so") + static offset from IDA/Ghidra dump

namespace OFF {
    // libil2cpp.dylib offsets
    static constexpr uintptr_t GameObjectManager = 0x063A4B20; // Il2CppObject* g_GameObjectManager
    static constexpr uintptr_t EntityList        = 0x068;      // List<Entity> inside manager
    static constexpr uintptr_t EntityCount        = 0x018;
    static constexpr uintptr_t EntityItems        = 0x020;

    // Entity → PlayerController component chain
    static constexpr uintptr_t PlayerCtrl         = 0x030;
    static constexpr uintptr_t IsAlive            = 0x1A8;     // bool
    static constexpr uintptr_t Health             = 0x1AC;     // float
    static constexpr uintptr_t MaxHealth          = 0x1B0;     // float
    static constexpr uintptr_t IsEnemy            = 0x1C4;     // bool (team flag)

    // Transform chain
    static constexpr uintptr_t Transform          = 0x038;
    static constexpr uintptr_t TransformInternal  = 0x010;
    static constexpr uintptr_t Position           = 0x090;     // Vector3 (x,y,z floats)
    static constexpr uintptr_t BoneHead           = 0x0A0;     // bone[0] = head

    // Camera
    static constexpr uintptr_t MainCamera         = 0x064B2200;
    static constexpr uintptr_t ViewMatrix         = 0x0D0;     // float[16]

    // LocalPlayer
    static constexpr uintptr_t LocalPlayer        = 0x0641F580;
    static constexpr uintptr_t YawAngle           = 0x2A8;
    static constexpr uintptr_t PitchAngle         = 0x2AC;
}

// ── Memory helpers ─────────────────────────────────────────────────────────
static uintptr_t il2cppBase = 0;

static void resolve_base() {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char* name = _dyld_get_image_name(i);
        if (name && strstr(name, "libil2cpp")) {
            il2cppBase = (uintptr_t)_dyld_get_image_header(i);
            return;
        }
    }
}

template<typename T>
static T rpm(uintptr_t addr) {
    if (!addr || addr < 0x1000) return T{};
    return *reinterpret_cast<T*>(addr);
}

static uintptr_t rpm_ptr(uintptr_t addr) { return rpm<uintptr_t>(addr); }

// ── Math ───────────────────────────────────────────────────────────────────
struct Vec3 { float x, y, z; };
struct Vec2 { float x, y; };

static Vec2 world_to_screen(const float vm[16], Vec3 pos, float sw, float sh) {
    float clipX = vm[0]*pos.x + vm[4]*pos.y + vm[8]*pos.z  + vm[12];
    float clipY = vm[1]*pos.x + vm[5]*pos.y + vm[9]*pos.z  + vm[13];
    float clipW = vm[3]*pos.x + vm[7]*pos.y + vm[11]*pos.z + vm[15];
    if (clipW < 0.1f) return {-1,-1};
    float ndcX = clipX / clipW;
    float ndcY = clipY / clipW;
    return { (ndcX + 1.0f) * 0.5f * sw, (1.0f - ndcY) * 0.5f * sh };
}

static float angle_to(Vec3 from, Vec3 to) {
    float dx = to.x - from.x, dz = to.z - from.z;
    return atan2f(dx, dz) * (180.0f / M_PI);
}

static float pitch_to(Vec3 from, Vec3 to) {
    float dx = to.x - from.x, dy = to.y - from.y, dz = to.z - from.z;
    float dist = sqrtf(dx*dx + dz*dz);
    return -atan2f(dy, dist) * (180.0f / M_PI);
}

// ── State ──────────────────────────────────────────────────────────────────
struct PlayerInfo {
    Vec2  screen;
    Vec2  headScreen;
    float health;
    float maxHealth;
    bool  valid;
};

static std::vector<PlayerInfo> g_players;
static bool g_aimbotActive = false;
static UIWindow* g_overlayWin = nil;

// ── Overlay ────────────────────────────────────────────────────────────────
@interface ESPView : UIView @end
@implementation ESPView

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    for (auto& p : g_players) {
        if (!p.valid || p.screen.x < 0) continue;

        // box from feet to head
        float boxH = fabsf(p.screen.y - p.headScreen.y);
        float boxW = boxH * 0.4f;
        CGRect box = CGRectMake(p.screen.x - boxW*0.5f,
                                p.headScreen.y,
                                boxW, boxH);

        // health color: green → yellow → red
        float ratio = (p.maxHealth > 0) ? p.health / p.maxHealth : 0;
        CGContextSetRGBStrokeColor(ctx, 1.0f - ratio, ratio, 0, 1);
        CGContextSetLineWidth(ctx, 1.5f);
        CGContextStrokeRect(ctx, box);

        // HP text
        NSString* hpStr = [NSString stringWithFormat:@"%.0f", p.health];
        NSDictionary* attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:9],
            NSForegroundColorAttributeName: [UIColor whiteColor]
        };
        [hpStr drawAtPoint:CGPointMake(box.origin.x, box.origin.y - 12) withAttributes:attrs];
    }

    // aimbot crosshair indicator
    if (g_aimbotActive) {
        float cx = rect.size.width  * 0.5f;
        float cy = rect.size.height * 0.5f;
        CGContextSetRGBStrokeColor(ctx, 1, 0, 0, 0.8f);
        CGContextSetLineWidth(ctx, 1.0f);
        CGContextMoveToPoint(ctx, cx-8, cy); CGContextAddLineToPoint(ctx, cx+8, cy);
        CGContextMoveToPoint(ctx, cx, cy-8); CGContextAddLineToPoint(ctx, cx, cy+8);
        CGContextStrokePath(ctx);
    }
}
@end

// ── Game loop hook ─────────────────────────────────────────────────────────
// Hook: UnityEngine.PlayerLoop::Update via MSHookFunction on il2cpp vtable
// Alternative if vtable shifts: hook objc_msgSend filter for "Update"

static void (*orig_update)(void*) = nullptr;

static void hooked_update(void* self) {
    if (orig_update) orig_update(self);

    if (!il2cppBase) { resolve_base(); return; }

    uintptr_t mgr  = rpm_ptr(il2cppBase + OFF::GameObjectManager);
    uintptr_t list = rpm_ptr(mgr + OFF::EntityList);
    int       cnt  = rpm<int>(list + OFF::EntityCount);
    uintptr_t items= rpm_ptr(list + OFF::EntityItems);

    // camera
    uintptr_t cam  = rpm_ptr(il2cppBase + OFF::MainCamera);
    float vm[16];
    memcpy(vm, reinterpret_cast<void*>(cam + OFF::ViewMatrix), sizeof(vm));

    CGSize screen = UIScreen.mainScreen.bounds.size;

    // local player for aimbot
    uintptr_t local = rpm_ptr(il2cppBase + OFF::LocalPlayer);
    uintptr_t localTf = rpm_ptr(rpm_ptr(local + OFF::Transform) + OFF::TransformInternal);
    Vec3 localPos = rpm<Vec3>(localTf + OFF::Position);

    std::vector<PlayerInfo> frame;
    float bestDist = 180.0f;
    float bestYaw = 0, bestPitch = 0;

    for (int i = 0; i < cnt && i < 60; i++) {
        uintptr_t ent = rpm_ptr(items + 0x20 + i * 0x8);
        if (!ent) continue;

        uintptr_t ctrl = rpm_ptr(ent + OFF::PlayerCtrl);
        if (!ctrl) continue;

        bool alive  = rpm<bool>(ctrl + OFF::IsAlive);
        bool enemy  = rpm<bool>(ctrl + OFF::IsEnemy);
        if (!alive || !enemy) continue;

        float hp    = rpm<float>(ctrl + OFF::Health);
        float maxHp = rpm<float>(ctrl + OFF::MaxHealth);
        if (hp <= 0) continue;

        uintptr_t tf   = rpm_ptr(rpm_ptr(ent + OFF::Transform) + OFF::TransformInternal);
        Vec3 feetPos   = rpm<Vec3>(tf + OFF::Position);
        Vec3 headPos   = rpm<Vec3>(tf + OFF::BoneHead);

        Vec2 feet  = world_to_screen(vm, feetPos, screen.width, screen.height);
        Vec2 head  = world_to_screen(vm, headPos, screen.width, screen.height);

        frame.push_back({feet, head, hp, maxHp, feet.x > 0});

        // aimbot: closest to crosshair (angle delta from center)
        float yaw   = angle_to(localPos, headPos);
        float pitch = pitch_to(localPos, headPos);
        float dy    = yaw   - rpm<float>(il2cppBase + OFF::LocalPlayer + OFF::YawAngle);
        float dp    = pitch - rpm<float>(il2cppBase + OFF::LocalPlayer + OFF::PitchAngle);
        float angDist = sqrtf(dy*dy + dp*dp);
        if (angDist < bestDist) {
            bestDist  = angDist;
            bestYaw   = yaw;
            bestPitch = pitch;
        }
    }

    g_players = frame;

    // aimbot apply — only while ADS (check isADS flag or gesture)
    if (g_aimbotActive && bestDist < 45.0f) {
        // write yaw/pitch directly to LocalPlayer angle fields
        *reinterpret_cast<float*>(il2cppBase + OFF::LocalPlayer + OFF::YawAngle)   = bestYaw;
        *reinterpret_cast<float*>(il2cppBase + OFF::LocalPlayer + OFF::PitchAngle) = bestPitch;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [g_overlayWin.rootViewController.view setNeedsDisplay];
    });
}

// ── Toggle gesture (3-finger tap) ─────────────────────────────────────────
static void setup_gesture(UIWindow* win) {
    UITapGestureRecognizer* tap =
        [[UITapGestureRecognizer alloc]
            initWithTarget:nil action:nil];
    tap.numberOfTouchesRequired = 3;
    [tap addTarget:[NSBlockOperation blockOperationWithBlock:^{
        g_aimbotActive = !g_aimbotActive;
    }] action:@selector(main)];
    [win addGestureRecognizer:tap];
}

// ── Init ───────────────────────────────────────────────────────────────────
__attribute__((constructor))
static void init() {
    resolve_base();
    if (!il2cppBase) return;

    // hook PlayerLoop Update — offset to UnityEngine PlayerLoop::Update vtable fn
    // derive this offset via Ghidra: search "PlayerLoop" xrefs in libil2cpp
    static constexpr uintptr_t UPDATE_FN = 0x02B4A930; // re-derive per version
    uintptr_t target = il2cppBase + UPDATE_FN;
    MSHookFunction(reinterpret_cast<void*>(target),
                   reinterpret_cast<void*>(hooked_update),
                   reinterpret_cast<void**>(&orig_update));

    // overlay window
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene* scene = nil;
        for (UIScene* s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene*)s; break; }
        }
        CGRect bounds = UIScreen.mainScreen.bounds;
        g_overlayWin = [[UIWindow alloc] initWithFrame:bounds];
        if (scene) [g_overlayWin setWindowScene:scene];
        g_overlayWin.windowLevel = UIWindowLevelAlert + 100;
        g_overlayWin.backgroundColor = [UIColor clearColor];
        g_overlayWin.userInteractionEnabled = YES;

        UIViewController* vc = [UIViewController new];
        ESPView* esp = [[ESPView alloc] initWithFrame:bounds];
        esp.backgroundColor = [UIColor clearColor];
        esp.opaque = NO;
        esp.userInteractionEnabled = NO;
        [vc.view addSubview:esp];
        g_overlayWin.rootViewController = vc;
        [g_overlayWin makeKeyAndVisible];
        setup_gesture(g_overlayWin);
    });
}
