#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <math.h>
#import "DYYYFullscreenGeometry.h"

static int DYYYFullscreenGeometryCheck(BOOL passed, const char *name) {
    printf("%s fullscreen geometry: %s\n", passed ? "PASS" : "FAIL", name);
    return passed ? 0 : 1;
}

static int DYYYFullscreenExpectFrame(CGRect current, CGRect saved, CGRect applied, BOOL adjusted,
                                     CGRect expected, const char *name) {
    CGRect result = [DYYYFullscreenGeometry nativePlayerFrameForLayout:current savedNative:saved
                                                        lastApplied:applied adjusted:adjusted];
    return DYYYFullscreenGeometryCheck(CGRectEqualToRect(result, expected), name);
}

int DYYYRunFullscreenGeometryTests(void) {
    int failures = 0;
    CGRect saved = CGRectMake(0, -27.95, 393, 792);
    CGRect applied = CGRectMake(0, 59, 393, 400);
    struct { CGRect frame; const char *name; } nativeCases[] = {
        {CGRectMake(0, 0, 393, 852), "原生 y=0 与 852pt 高度原样保留"},
        {saved, "原生负 y 与 792pt 高度不强制归零或铺满"},
        {CGRectMake(12, 24, 320, 568), "非全宽及小窗原生位置不变"},
        {CGRectMake(0, 120, 393, 852), "原生非零原点不替换为宿主 bounds"},
        {CGRectMake(0, 0, 852, 393), "旋转后的原生宽高不沿用旧帧"},
        {CGRectMake(0.25, -0.125, 392.5, 791.75), "原生小数坐标与尺寸精确保留"},
        {CGRectZero, "尚未就绪的零尺寸不从上一条补造"}
    };
    for (NSUInteger i = 0; i < sizeof(nativeCases) / sizeof(nativeCases[0]); i++) {
        failures += DYYYFullscreenExpectFrame(nativeCases[i].frame, saved, applied, NO,
                                              nativeCases[i].frame, nativeCases[i].name);
    }
    failures += DYYYFullscreenExpectFrame(applied, saved, applied, NO, applied,
        "未接管时即使等于上次结果也不重放缓存");
    failures += DYYYFullscreenExpectFrame(applied, saved, applied, YES, saved,
        "评论仍是自身最后改写时精确恢复原生负 y 和高度");
    CGRect moved = CGRectOffset(applied, 0, 0.001);
    failures += DYYYFullscreenExpectFrame(moved, saved, applied, YES, moved,
        "原生 center 微调后不被旧缓存拉回");
    CGRect resized = applied;
    resized.size.height += 1;
    failures += DYYYFullscreenExpectFrame(resized, saved, applied, YES, resized,
        "原生 bounds 改变后使用实际尺寸");
    failures += DYYYFullscreenExpectFrame(applied, saved, applied, NO, applied,
        "作品或宿主失效清除 adjusted 后不恢复前一条");

    BOOL waiting = [DYYYFullscreenGeometry awaitsNativePlayerFrame:NO adjusted:YES current:applied lastApplied:applied];
    failures += DYYYFullscreenGeometryCheck(waiting, "A 评论结果留在复用播放器上时，B 等待自己的原生几何");
    for (NSUInteger round = 0; round < 3; round++) {
        waiting = [DYYYFullscreenGeometry awaitsNativePlayerFrame:waiting adjusted:NO current:applied lastApplied:applied];
        failures += DYYYFullscreenGeometryCheck(waiting, "清空 adjusted 后多轮 prepare 也不能把 A 的结果洗成 B 原生帧");
    }
    waiting = [DYYYFullscreenGeometry awaitsNativePlayerFrame:waiting adjusted:NO current:moved lastApplied:applied];
    failures += DYYYFullscreenGeometryCheck(!waiting, "实际原生几何已离开旧自身结果时才可重建基准");
    failures += DYYYFullscreenGeometryCheck(![DYYYFullscreenGeometry awaitsNativePlayerFrame:NO adjusted:NO current:applied lastApplied:applied],
        "新原生 setter 明确解除等待后，同值输入仍归原生所有");
    failures += DYYYFullscreenGeometryCheck([DYYYFullscreenGeometry isUsablePlayerFrame:saved],
        "合法负 y 不是坏坐标");

    CGRect invalid[] = {CGRectZero, CGRectNull, CGRectInfinite,
        CGRectMake(NAN, 0, 393, 792), CGRectMake(0, NAN, 393, 792),
        CGRectMake(0, 0, INFINITY, 792), CGRectMake(0, 0, 393, NAN),
        CGRectMake(0, 0, -393, 792)};
    for (NSUInteger i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++) {
        failures += DYYYFullscreenExpectFrame(applied, invalid[i], applied, YES, applied,
            "无效或非有限的保存坐标不得恢复");
    }
    CGRect previousCell = CGRectMake(0, 852, 393, 852);
    CGRect currentCell = CGRectMake(0, 0, 393, 852);
    CGRect previousNormal = CGRectMake(0, 824.05, 393, 792);
    CGRect translated = [DYYYFullscreenGeometry translateRect:previousNormal fromReference:previousCell toReference:currentCell];
    failures += DYYYFullscreenGeometryCheck(fabs(translated.origin.y + 27.95) < 0.0001 &&
        translated.size.height == 792, "同一页从预加载滚入时只平移 cell 基准，不混用窗口绝对 y");
    failures += DYYYFullscreenGeometryCheck(CGRectIsNull([DYYYFullscreenGeometry translateRect:previousNormal
        fromReference:previousCell toReference:CGRectMake(0, 0, 852, 393)]),
        "cell 尺寸变化时拒绝旧评论基准");
    CGRect viewport = CGRectMake(0, 0, 393, 852);
    CGRect panel = CGRectMake(0, 500, 393, 352);
    CGRect available = [DYYYFullscreenGeometry unoccludedViewport:viewport top:59 panel:panel gap:0];
    failures += DYYYFullscreenGeometryCheck(CGRectEqualToRect(available, CGRectMake(0, 59, 393, 441)),
        "普通评论仍使用状态栏下沿到面板上沿的可用区");
    CGRect fit = [DYYYFullscreenGeometry aspectFit:CGSizeMake(1920, 1080) inRect:available];
    failures += DYYYFullscreenGeometryCheck(fabs(fit.size.width - 393) < 0.0001 &&
        fabs(fit.size.height - 221.0625) < 0.0001 && CGRectContainsRect(available, fit),
        "普通评论仍等比适配真实渲染比例");
    failures += DYYYFullscreenGeometryCheck(CGRectIsNull([DYYYFullscreenGeometry aspectFit:CGSizeZero inRect:available]),
        "未知媒体尺寸不制造评论缩放");
    return failures;
}
