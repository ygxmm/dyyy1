#!/usr/bin/env python3
"""头像独立控制的源码接线检查；不替代 UIKit/真机触控验收。"""
from pathlib import Path
import re
root=Path(__file__).resolve().parents[2]
xm=(root/'DYYY.xm').read_text()
policy=(root/'Sources/Features/DYYYAvatarInteractionPolicy.h').read_text()
runtime=(root/'Sources/Features/DYYYAvatarActionRuntime.h').read_text()
primary=(root/'DYYYSettings.xm').read_text()
secondary=(root/'Sources/Settings/DYYYSettingViewController.m').read_text()
helper=(root/'Sources/Settings/DYYYSettingsHelper.m').read_text()
checks=0
def check(ok,meaning):
 global checks
 checks+=1
 print(('PASS' if ok else 'FAIL')+' avatar-wiring: '+meaning)
 if not ok:raise SystemExit(1)

for key,title in [('DYYYAvatarFollowRemoveVisualKey','隐藏头像加号'),('DYYYAvatarFollowDeleteKey','移除头像加号')]:
 check(len(re.findall(r'@"identifier"\s*:\s*'+key+r'\b',primary))==1 and len(re.findall(r'\bkey:'+key+r'\b',secondary))==1,'原关注键两处各一项：'+key)
 check(re.search(r'@"identifier"\s*:\s*'+key+r'\s*,\s*@"title"\s*:\s*@"'+title+r'"',primary) is not None and re.search(r'itemWithTitle:@"'+title+r'" key:'+key,secondary) is not None,'保留原关注名称：'+title)
 check(primary.index(key,primary.index('NSArray *videoUiSettings'))<primary.index('DYYYHideLikeLabel',primary.index('NSArray *videoUiSettings')) and secondary.index('key:'+key)<secondary.index('key:@"DYYYHideLikeLabel"'),'保留原关注行位置：'+title)
check('删除关注（不可点击）' not in primary+secondary and '移除关注（可点击）' not in primary+secondary,'没有另加或改名第二对关注功能')
check('原始位置可点击' in primary and '完全移除不可点击' in primary,'原点击语义在主设置说明中保留')
for name in ('SendMessage','EnterStore','AdLink'):
 key='DYYYHideAvatar'+name+'Key'
 check(len(re.findall(r'@"identifier"\s*:\s*'+key+r'\b',primary))==1 and len(re.findall(r'\bkey:'+key+r'\b',secondary))==1,'拆出的附加入口各自唯一：'+name)
 check(key in policy and key in runtime and key in (root/'Sources/Settings/DYYYSettingsBackupValidation.m').read_text(),'独立键从UI到策略、备份接通：'+name)
check('DYYYAvatarFollowRemoveVisualKey : @[ DYYYAvatarFollowDeleteKey ]' in helper and 'DYYYAvatarFollowDeleteKey : @[ DYYYAvatarFollowRemoveVisualKey ]' in helper,'仅原关注两项互斥')
for old in ('DYYYAvatarFollowOptionsEnabled','DYYYApplyAvatarFollowPromptSettings','DYYYAvatarAuxiliaryActionSelectorGroups','DYYYRemoveAvatarView','kDYYYAvatarActionRemovedViewKey','kDYYYAvatarFollowScopeViewKey'):
 check(old not in xm+runtime,'删除旧混合处理路径：'+old)
check(xm.count('#import "DYYYAvatarActionRuntime.h"')==1 and xm.count('DYYYInstallAvatarActionRuntime();')==1,'新运行时只链接与安装一次')
check('layer.opacity =' not in runtime and 'view.alpha =' not in runtime and 'hitTest:' not in runtime,'视觉隐藏不改变alpha、opacity或重写热区')
for cls in ('AWEPlayInteractionUserAvatarSendMessageController','AWEPlayInteractionUserAvatarSendMsgController','AWEPlayInteractionUserAvatarEnterStoreController','AWEPlayInteractionUserAvatarAdLinkController'):
 h=re.search(r'(?ms)^%hook '+cls+r'\b(.*?)^%end',xm)
 check(h is not None and 'DYYYHideFollowPromptView' not in h.group(1) and 'DYYYHideLOTAnimationView' not in h.group(1),cls+'不再读取关注键')
check('DYYYRunAvatarInteractionPolicyTests' in (root/'Tests/Media/DYYYLikeMediaTests.m').read_text() and 'DYYYAvatarInteractionPolicyTests.m' in (root/'Tests/Media/run_media_tests.sh').read_text(),'真实策略回归进入原生CI总入口')
check('DYYYHideAvatarLive") ||' not in xm and 'DYYYHideAvatarLive") ||' not in runtime,'直播提示没有人为连到头像本体隐藏')
print(f'{checks} avatar integration checks passed; native/device verification separate.')
