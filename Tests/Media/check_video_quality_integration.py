#!/usr/bin/env python3
"""Guard class/selector wiring, not a device playback test."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
source = (root / 'DYYY.xm').read_text()

def hook_methods(text, class_name):
    blocks = re.findall(r'^%hook ' + re.escape(class_name) + r'\s*\n(.*?)^%end', text, re.M | re.S)
    assert len(blocks) == 1, 'Keep one hook for actual runtime class: ' + class_name
    block, methods = blocks[0], {}
    for match in re.finditer(r'^-\s*\([^\n)]+\)\s*([^\n{]+)\{', block, re.M):
        signature = match.group(1).strip()
        parts = re.findall(r'([A-Za-z_]\w*)\s*:', signature)
        selector = ''.join(part + ':' for part in parts) if parts else signature
        depth, end = 1, match.end()
        while depth and end < len(block):
            depth += (block[end] == '{') - (block[end] == '}')
            end += 1
        assert selector not in methods, 'Duplicate selector in ' + class_name + ': ' + selector
        methods[selector] = block[match.end():end - 1]
    return block, methods

expected = {
    'AWEVideoModel': {'preloadedBSModel': '%orig'},
    'BDSimPlayStreamSelector': {
        'selectPlayVideoBSModelWithCurrentBSModel:currentGearType:enableSR:': '%orig(currentBSModel, gearType, enableSR)',
    },
}

def check_native_boundaries(text, emit=False):
    for obsolete in ('BDSimBitrateSelector', 'BDSimPrefetchBitrateSelector'):
        assert not re.search(r'^%hook ' + obsolete + r'\s*$', text, re.M), 'Remove bypassed helper hooks: ' + obsolete
    for class_name, selectors in expected.items():
        block, methods = hook_methods(text, class_name)
        assert not any(s.startswith('__') for s in methods), 'Do not retain the old private-helper stack: ' + class_name
        for selector, original in selectors.items():
            assert selector in methods, 'Missing actual public boundary: ' + class_name + ' ' + selector
            body = methods[selector]
            assert body.count('%orig') == 1 and original in body, 'Preserve arguments/bookkeeping once: ' + selector
            if class_name == 'AWEVideoModel':
                assert body.strip().startswith('id nativeTier = ' + original + ';'), selector
                assert body.strip().endswith('return DYYYPreferredNativePlaybackTier(self, nativeTier, NO);'), selector
                assert body.count('return ') == 1, selector
            else:
                assert body.strip().startswith('return DYYYRunNativeSelectorSelection(self, ^id{'), selector
                assert body.strip().endswith('});') and body.count('return ') == 2, selector
                assert 'return ' + original + ';' in body, 'Native arguments survive the selection scope: ' + selector
            if emit:
                print('PASS native quality wiring:', class_name, selector)
        for forbidden in ('setPreloadedBSModel:', 'setPlayBSModel:', 'setBsModel:', 'setEnableHDR:', 'setHdrType:', 'setHdrBit:'):
            assert forbidden not in block, 'No native cache/metadata writes: ' + forbidden

check_native_boundaries(source, emit=True)
# Negative checks: removing an actual class/entrypoint must fail. Merely listing
# a selector in a comment, or hooking the same name on AWE, cannot satisfy it.
for class_name in expected:
    mutant = source.replace('%hook ' + class_name + '\n', '%hook DYYYMissingBoundary\n', 1)
    try:
        check_native_boundaries(mutant)
    except AssertionError:
        pass
    else:
        raise AssertionError('Class ownership mutation was not detected: ' + class_name)
print('PASS native quality wiring: wrong-class regressions are rejected')
assert 'DYYYPlaybackQualityModeForSettings(' in source
assert 'DYYYResolveNativePlaybackTierForVideo(nativeTier, video, mode, hdrAllowed)' in source
bridge = re.search(r'static id DYYYPreferredNativePlaybackTier\(.*?\n\}', source, re.S).group(0)
assert 'objc_msgSend)(owner, modelGetter)' in bridge and 'objc_msgSend)(model, videoGetter)' in bridge and '@catch' in bridge
assert bridge.index('mode == DYYYPlaybackQualityOriginal') < bridge.index('modelGetter')
assert 'mode != DYYYPlaybackQualityPreferHDR' not in bridge, 'Both enabled policies must reach native coordination'
assert bridge.index('DYYYNativeHDRPlaybackAllowed()') < bridge.index('modelGetter')
assert 'dyyyNativeSelectionDepth ||' in bridge and 'resolvingNativeTier' in bridge
bridge_code = re.sub(r'//[^\n]*|/\*.*?\*/', '', bridge, flags=re.S)
assert 'current' not in bridge_code.lower(), 'Never borrow a global visible video for prefetch ownership'
scope = re.search(r'static id DYYYRunNativeSelectorSelection\(.*?\n\}', source, re.S).group(0)
assert scope.count('nativeSelection()') == 1 and '@finally' in scope
assert '++dyyyNativeSelectionDepth;' in scope and '--dyyyNativeSelectionDepth;' in scope
assert scope.index('--dyyyNativeSelectionDepth;') < scope.index('return DYYYPreferredNativePlaybackTier')
assert 'return DYYYPreferredNativePlaybackTier(selector, nativeTier, YES);' in scope
print('PASS native quality wiring: guards precede owner reads; nested selection coordinates only on exit')
policy = (root / 'Sources/Media/DYYYVideoQualityPolicy.m').read_text()
addresses = re.search(r'static id DYYYPreferredPlaybackTier\(.*?\n\}', source, re.S).group(0)
assert 'DYYYSelectPlaybackTier(video.bitrateModels, mode, DYYYNativeHDRPlaybackAllowed())' in addresses
resolver = re.search(r'^id DYYYResolveNativePlaybackTier\(.*?\n\}', policy, re.M | re.S).group(0)
assert 'DYYYSelectPlaybackTier(tiers, mode, nativeHDRAllowed)' in resolver
assert 'DYYYPlaybackSameSource(nativeTier, tier)' in resolver
assert 'DYYYPlaybackTierHasUsableSource(nativeTier)' in resolver
assert 'DYYYSelectHighestAllowedPlaybackTier(tiers, nativeHDRAllowed)' in policy
assert 'DYYYPlaybackTierHasUsableSource(tier)' in policy
print('PASS native quality wiring: addresses and native results share both policies and allowed-source fallback')
for filename in ('DYYYSettings.xm', 'Sources/Settings/DYYYSettingViewController.m'):
    ui = (root / filename).read_text()
    assert re.search(r'@\[\s*DYYY_VIDEO_QUALITY_OFF,\s*DYYY_VIDEO_QUALITY_HIGHEST,\s*DYYY_VIDEO_QUALITY_PREFER_HDR\s*\]', ui), filename
    assert 'DYYYNormalizedPlaybackQualityPolicy(' in ui, filename
    print('PASS native quality wiring: Off option and normalized display in', filename)
print('Native quality structural checks passed; native playback still requires device verification.')
