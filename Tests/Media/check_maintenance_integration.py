#!/usr/bin/env python3
"""维护集成结构检查，不替代 macOS 原生断言或真机测试。"""
from pathlib import Path
import re
r=Path(__file__).resolve().parents[2]
def check(ok,reason):
 print(('PASS' if ok else 'FAIL')+' maintenance wiring: '+reason)
 if not ok: raise SystemExit(1)
make=(r/'Makefile').read_text(); manager=(r/'Sources/Media/DYYYManager.m').read_text()
xm=(r/'DYYY.xm').read_text(); panel=(r/'DYYYLongPressPanel.xm').read_text()
like=(r/'Sources/Features/DYYYLikeLongPressSave.m').read_text()
check('pendingAlbumDescription' not in manager,'不再保存跨入口单例作品说明')
check('setAlbumDescriptionContextWithAwemeModel:' not in xm+panel,'作品菜单使用显式说明参数')
check('DYYYLikeSave.LivePhoto' in like and like.count('DYYYLikeSaveStandaloneLiveItems(model)')==2,'点赞与旧菜单共用新版实况资源构造')
photo=like.split('static void DYYYLikeSaveMediaFiles(',1)[1].split('@interface DYYYLikeGallerySaveJob',1)[0]
submission=photo.split('performChanges:^{',1)[1].split('} completionHandler:',1)[0]
check(re.fullmatch(r'\s*DYYYDownloadPerformIfActive\(state, \^\{.*\}\);\s*',submission,re.S) is not None
      and all(x in submission for x in ('creationRequestForAsset','addResourceWithType:PHAssetResourceTypePhoto','addResourceWithType:PHAssetResourceTypePairedVideo'))
      and like.count('creationRequestForAsset')==1,'点赞静图与实况的真实 PhotoKit 创建均在取消闸门内')
check('self.lifecycleState = DYYYDownloadCreateState();' in like
      and 'DYYYLikeSaveMediaFiles(imageURL, nil, creationDate, self.lifecycleState,' in like
      and 'DYYYLikeSaveMediaFiles(photo, video, creationDate, self.lifecycleState,' in like
      and re.search(r'if \(!DYYYDownloadCancelState\(job\.lifecycleState\)\) return;\s*job\.cancelled = YES;\s*\[job\.task cancel\];',like)
      and 'DYYYDownloadFinishState(self.lifecycleState);' in like,'点赞图集启动、两个保存入口、取消和终态共享任务状态')
check(re.search(r'if \(!DYYYDownloadStateIsActive\(state\)\) \{\s*completion\(DYYYLikeSaveError\(.+?\)\);\s*return;',
                photo.split('} completionHandler:',1)[1],re.S) is not None,'取消后的空 PhotoKit 事务不作为成功')
check('DYYYLikeStartGallerySave(snapshot, nil)' in like,'保留点赞图片原动作不嵌作品说明')
check('dyyy_containsHDRMetadataInObject' not in xm and 'DYYYAwemeRawVideoHasHDRMetadata(arg1)' in xm,'原始 HDR 检查限定当前视频结构')
check('AWEFeedRefreshFooter' not in xm,'删除未安装的 footer 死构造器，没有另加 Hook')

# 只控制视频右侧头像各自的原生显隐；不靠全局 UIView 或拦截播放/点击。
avatar_checks = (
 ('AWEPlayInteractionUserAvatarElement', 'shouldShowColorRing', 'StoryRing'),
 ('AWEPlayInteractionUserAvatarElement', 'shouldShowAvatarDecoration:(id)model', 'Decoration'),
 ('AWEPlayInteractionUserAvatarStoryController', 'shouldShowColorRing:(id)model', 'StoryRing'),
 ('AWEPlayInteractionUserAvatarDecorationController', 'shouldShowAvatarDecoration:(id)model', 'Decoration'),
)
for cls, signature, kind in avatar_checks:
 hook = re.search(r'(?ms)^%hook '+cls+r'\b(.*?)^%end\b',xm)
 entry = re.search(r'-\s*\(BOOL\)\s*'+re.escape(signature)+r'\s*\{([^}]+)\}',hook.group(1)) if hook else None
 check(entry and re.fullmatch(r'\s*return DYYYAvatarSurroundingHidden\(DYYYAvatarSurrounding'+kind+r'\) \? NO : %orig(?:\(model\))?;\s*', entry.group(1)),
       cls+' '+signature+' 仅受对应分项控制，关闭走原生')
settings=(r/'DYYYSettings.xm').read_text()
fallback=(r/'Sources/Settings/DYYYSettingViewController.m').read_text()
keys=('DYYYHideAvatarStoryRingKey','DYYYHideAvatarDecorationKey')
check(all(key in settings and key in fallback for key in keys) and '隐藏头像周边' not in settings,
      '主设置和备用设置均展示两项并移除旧总开关')
check('DYYYApplyAvatarSurroundingSettingsForOwner' not in xm and 'DYYYShouldForceAvatarSurroundingViewHidden' not in xm
      and '@"DYYYHideAvatarSurrounding"' not in xm and '@"DYYYHideAvatarLive"' in settings,
      '旧周边视图兜底已移除，直播提示设置仍独立')

check('DYYYNowPlayingPrivacy.m' in make and 'DYYYNowPlayingPolicy.m' in make and
      'AVKit MediaPlayer' in make and 'media.now-playing-privacy' in (r/'Sources/Hooking/DYYYHookManager.m').read_text(),
      '统一Now Playing策略在loader-safe阶段安装并链接系统会话框架')
check('DYYYApplyNowPlayingPrivacySettingChange' in settings and 'DYYYApplyNowPlayingPrivacySettingChange' in fallback and
      (r/'Sources/Features/DYYYNowPlayingPrivacy.h').is_file() and (r/'Sources/Features/DYYYNowPlayingPolicy.h').is_file(),
      '主/备用开关持久化后都通知同一运行时状态机')
check('DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY' in (r/'Sources/Settings/DYYYSettingsBackupValidation.m').read_text() and
      'DYYYApplyNowPlayingPrivacySettingChange' in settings and
      'DYYYApplyFeedNowPlayingSettingChange' not in xm and
      'MRMediaRemoteSetCanBeNowPlayingApplication' not in xm,
      '备份采用严格布尔值；旧全局清空与源对象早退入口已移除')
check('MPNowPlayingSession' in (r/'Sources/Features/DYYYNowPlayingPrivacy.m').read_text() and
      'AVPlayerViewController' in (r/'Sources/Features/DYYYNowPlayingPrivacy.m').read_text() and
      'MPNowPlayingInfoCenter' in (r/'Sources/Features/DYYYNowPlayingPrivacy.m').read_text() and
      'class_getInstanceMethod(cls, NSSelectorFromString(selectorName))' in (r/'Sources/Features/DYYYNowPlayingPrivacy.m').read_text() and
      'MRMediaRemoteSetCanBeNowPlayingApplication' not in (r/'Sources/Features/DYYYNowPlayingPrivacy.m').read_text(),
      '运行时校验新版会话入口，屏蔽应用私有资格全局副作用')

check('DYYYRunNowPlayingPolicyTests' in (r/'Tests/Media/DYYYLikeMediaTests.m').read_text() and
      'DYYYNowPlayingPolicyTests.m' in (r/'Tests/Media/run_media_tests.sh').read_text(),
      '策略切换/原生恢复合成断言确实进入CI执行')

for helper in ('Sources/Core/DYYYABConfigValidation.m','Sources/Settings/DYYYSettingsBackupValidation.m'):
    check(make.count(helper)==1 and (r/helper).is_file(),helper+' 仅加入编译一次')
# 仅扫描实际参与编译的 Logos 文件，不把历史版本片段当成生效 Hook。
sources=re.search(r'DYYY_FILES\s*=\s*(.*?)\nDYYY_CFLAGS',make,re.S).group(1).replace('\\','').split()
seen={};duplicates=[]
for file in sources:
 if not file.endswith(('.xm','.x')): continue
 text=(r/file).read_text()
 text=re.sub(r'/\*.*?\*/|//[^\n]*','',text,flags=re.S)
 for hook in re.finditer(r'%hook\s+(\w+)\b(.*?)(?=%end\b)',text,re.S):
  cls,body=hook.groups()
  for method in re.finditer(r'^\s*([-+])\s*\([^)]*\)\s*([^;{]+)\{',body,re.M):
   kind,signature=method.groups();labels=re.findall(r'\b(\w+)\s*:',signature)
   selector=''.join(label+':' for label in labels) if labels else signature.strip().split()[0]
   key=(cls,kind,selector)
   if key in seen: duplicates.append((key,seen[key],file))
   seen[key]=file
check(not duplicates,'实际编译 Logos selector 无重复（%d 个）'%len(seen)+(' '+str(duplicates) if duplicates else ''))
print('Maintenance structural checks passed; native tests and device verification are separate.')
