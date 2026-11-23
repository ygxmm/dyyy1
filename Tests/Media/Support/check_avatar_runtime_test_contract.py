#!/usr/bin/env python3
"""只读源码接线检查，不是 macOS 编译或 UIKit/真机验收。"""
from pathlib import Path
import hashlib
import re

root = Path(__file__).resolve().parents[3]
runtime_path = root / 'Sources/Features/DYYYAvatarActionRuntime.h'
policy_path = root / 'Sources/Features/DYYYAvatarInteractionPolicy.h'
xm_path = root / 'DYYY.xm'
runtime = runtime_path.read_text()
xm = xm_path.read_text()
failed = 0

def check(ok, message):
    global failed
    print(('PASS' if ok else 'FAIL') + ' AvatarRuntime/source-contract: ' + message)
    failed += not ok

for symbol in ('DYYYAvatarActionRecordNative', 'DYYYAvatarActionIsOwnWrite',
               'DYYYAvatarActionBindView', 'DYYYAvatarActionBindLayer',
               'DYYYAvatarActionRetargetState', 'DYYYAvatarActionRefreshTrackedObjects',
               'DYYYAvatarActionBoundaryForView', 'DYYYAvatarActionValue',
               'DYYYApplyAvatarActionSettingsWithRetry', 'DYYYAvatarActionTargetDetached'):
    check(symbol in runtime, '真实头仍提供测试调用的 ' + symbol)

# P1-1 的跨 TU 接线缝：夹具不导入 DYYY.xm，必须另查没有资格强制 NO hook。
for name in ('AWEPlayInteractionUserAvatarElement',
             'AWEPlayInteractionUserAvatarSendMessageController',
             'AWEPlayInteractionUserAvatarSendMsgController',
             'AWEPlayInteractionUserAvatarEnterStoreController'):
    hook = re.search(r'(?ms)^%hook ' + re.escape(name) + r'\b(.*?)^%end', xm)
    check(hook is not None, '存在原生路径 ' + name)
    if hook:
        check(not re.search(r'(?m)^\s*[-+]\s*\(BOOL\)\s*(?:shouldShow|shouldPlay)\w*(?:SendMessage|EnterStore)\w*', hook.group(1)),
              name + ' 未重新覆写消息/店铺 BOOL 资格谓词')
        for method in re.finditer(r'(?ms)^-\s*\(void\)\s*(play(?:SendMessage|EnterStore)GuideAnimationIfNeeded)\s*\{(.*?)^\}', hook.group(1)):
            body = method.group(2)
            check(body.count('%orig') == 1 and 'return;' not in body,
                  name + '.' + method.group(1) + ' 原生流程准确一次且不提前跳过')

# 最后两项失效/性能接线，原生状态断言仍由真实头+测试double执行。
check('DYYYAvatarActionObjectInsideBoundary(state.object, root)' in runtime and
      'DYYYAvatarActionBoundaryHasLiveClaim(boundary, root)' in runtime,
      'Scope 同时检查活认领和实际对象成员关系')
check('@implementation DYYYAvatarActionOwnerLifetime' in runtime and
      'claim.valid = NO' in runtime and 'DYYYAvatarActionScheduleReconcile();' in runtime,
      'owner 生命周期撤销认领，恢复任务不持有 owner')
check('DYYYAvatarActionValidateStateClaim(state);' in runtime,
      '有标记的原生输入核对本 root getter，无布局通知也能失效')
check('DYYYAvatarActionValidateClaims(views);' in runtime and 'hintedKinds' not in runtime,
      '单kind及保护getter也进入低频有效性验证')
check('candidate.valid && candidate.owner == owner && candidate.view == view' in runtime and
      'if (!DYYYAvatarActionRegistrationDepth && DYYYAvatarActionNeedsReconcile())' in runtime,
      '稳定认领复用，同一登记链只在变化后解析')
check('DYYYAvatarActionResolveCount++' in runtime and
      'if (!__atomic_exchange_n(&DYYYAvatarActionTopologyDirty, NO, __ATOMIC_RELAXED)) return;' in runtime and
      'for (UIView *other in views)' not in runtime,
      '关系解析只对真实变化运行，不再全局两两比较')
for name, signature in [('UIView', 'didMoveToSuperview'), ('CALayer', 'removeFromSuperlayer')]:
    hook = re.search(r'(?ms)^%hook ' + name + r'\b(.*?)^%end', xm)
    method = re.search(r'-\s*\(void\)\s*' + signature + r'\s*\{([^}]+)\}', hook.group(1)) if hook else None
    check(method is not None and method.group(1).count('%orig') == 1 and
          method.group(1).index('%orig') < method.group(1).index('DYYYAvatarActionObjectTopologyDidChange'),
          name + '.' + signature + ' 在原生操作后撤销历史作用域')
tests = (root / 'Tests/Media/DYYYAvatarActionRuntimeTests.m').read_text()
for symbol in ('TestExpiredClaims', 'TestInheritedObjectsMoved', 'TestStableLayoutCost'):
    check(tests.count(symbol) == 2, '新增真实状态回归被总入口调用：' + symbol)

for path in (runtime_path, policy_path, xm_path):
    print('SOURCE_SHA256 ' + str(path.relative_to(root)) + ' ' + hashlib.sha256(path.read_bytes()).hexdigest())
print('NOTE source-contract only; Objective-C assertions require macOS Foundation+QuartzCore+UIKit-double execution.')
raise SystemExit(1 if failed else 0)
