#!/usr/bin/env python3
"""Structural guard for native hook wiring; not a device playback test."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
source = (root / 'DYYY.xm').read_text()
assert len(re.findall(r'^%hook AWEVideoModel\s*$', source, re.M)) == 1, 'Keep one AWEVideoModel hook'
block = re.search(r'^%hook AWEVideoModel\s*\n(.*?)^%end', source, re.M | re.S).group(1)
methods = {}
for match in re.finditer(r'^-\s*\([^\n)]+\)\s*([^\n{]+)\{', block, re.M):
    signature = match.group(1).strip()
    parts = re.findall(r'([A-Za-z_]\w*)\s*:', signature)
    selector = ''.join(part + ':' for part in parts) if parts else signature
    depth, end = 1, match.end()
    while depth and end < len(block):
        depth += (block[end] == '{') - (block[end] == '}')
        end += 1
    assert selector not in methods, 'Duplicate selector: ' + selector
    methods[selector] = block[match.end():end - 1]

expected = {
    'preloadedBSModel': '%orig',
    '__prefetchBSModelNeedSave:bandwidthFactor:': '%orig(needSave, factor)',
    '__prefetchBSModelWithAutoBitrateModel:needSave:bandwidthFactor:': '%orig(model, needSave, factor)',
    '__prefetchBSModelWithAwemeModel:needSave:bandwidthFactor:': '%orig(model, needSave, factor)',
    '__playBSModelBandwidthFactor:': '%orig(factor)',
    '__playDynamicBSModel:bandwidthFactor:': '%orig(model, factor)',
}
for selector, original in expected.items():
    body = methods[selector]
    assert body.count('%orig') == 1 and original in body, 'Preserve original arguments exactly once: ' + selector
    assert 'return DYYYPreferredNativePlaybackTier(self, nativeTier);' in body, 'Use the shared native resolver: ' + selector
    print('PASS native quality wiring:', selector)

assert 'DYYYPlaybackQualityModeForSettings(' in source
for forbidden in ('setPreloadedBSModel:', 'setPlayBSModel:', 'setEnableHDR:', 'setHdrType:', 'setHdrBit:'):
    assert forbidden not in block, 'No native cache or HDR metadata writes: ' + forbidden
assert 'resolvingNativeTier' in source and '@finally' in source
for filename in ('DYYYSettings.xm', 'Sources/Settings/DYYYSettingViewController.m'):
    ui = (root / filename).read_text()
    assert re.search(r'@\[\s*DYYY_VIDEO_QUALITY_OFF,\s*DYYY_VIDEO_QUALITY_HIGHEST,\s*DYYY_VIDEO_QUALITY_PREFER_HDR\s*\]', ui), filename
    assert 'DYYYNormalizedPlaybackQualityPolicy(' in ui, filename
    print('PASS native quality wiring: Off option and normalized display in', filename)
print('Native quality structural checks passed; native playback still requires device verification.')
