#import <Foundation/Foundation.h>
#import "../../Sources/Media/DYYYVideoQualityPolicy.h"

static int DYYYCheckHDRMetadata(BOOL value, const char *reason) {
    fprintf(stdout, "%s HDR metadata: %s\n", value ? "PASS" : "FAIL", reason);
    return value ? 0 : 1;
}

int DYYYRunHDRMetadataTests(void) {
    int failed = 0;
    // 位深不代表色彩传递函数，10 位 SDR 不应被当成 HDR 过滤。
    failed += DYYYCheckHDRMetadata(!DYYYPlaybackTierHasHDRMetadata(@{@"hdrBit": @10}), "10 位深不单独构成 HDR");
    failed += DYYYCheckHDRMetadata(DYYYPlaybackTierHasHDRMetadata(@{@"hdrType": @3}), "数值 HDR 标记");
    failed += DYYYCheckHDRMetadata(DYYYPlaybackTierHasHDRMetadata(@{@"hdrType": @"3"}), "完整字符串 HDR 标记");
    failed += DYYYCheckHDRMetadata(!DYYYPlaybackTierHasHDRMetadata(@{@"hdrType": @"3invalid"}), "畸形字符串不作 HDR 证据");
    failed += DYYYCheckHDRMetadata(!DYYYPlaybackTierHasHDRMetadata(NSNull.null), "未知模型不崩溃");
    failed += DYYYCheckHDRMetadata(!DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"bit_rate": @[@{@"HDR_bit": @10}]}}), "原始 10 位 SDR 放行");
    failed += DYYYCheckHDRMetadata(DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"bit_rate": @[@{@"HDR_type": @3}]}}), "识别原始大写 HDR_type");
    failed += DYYYCheckHDRMetadata(DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"bit_rate": @[@{@"hdr_type": @"1"}]}}), "兼容小写 hdr_type");
    failed += DYYYCheckHDRMetadata(DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"is_source_hdr": @1}}), "保留当前视频源 HDR 标记");
    failed += DYYYCheckHDRMetadata(DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"has_filter_hdr": @1}}), "保留原生 HDR 过滤标记");
    failed += DYYYCheckHDRMetadata(!DYYYAwemeRawVideoHasHDRMetadata(@{@"recommend": @{@"video": @{@"is_source_hdr": @1}}}), "相关推荐 HDR 不误杀当前作品");
    failed += DYYYCheckHDRMetadata(!DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"edit_info": @{@"hdr_type": @3}}}), "不递归扫描无关编辑信息");
    failed += DYYYCheckHDRMetadata(!DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @[@{@"hdr_type": @3}]}), "畸形视频结构放行");
    failed += DYYYCheckHDRMetadata(!DYYYAwemeRawVideoHasHDRMetadata(@{@"video": @{@"bit_rate": @[@1, NSNull.null, @{@"hdr_type": @"1x"}]}}), "畸形码流结构不会崩溃或误判");
    failed += DYYYCheckHDRMetadata(!DYYYAwemeRawVideoHasHDRMetadata(nil), "空原始对象放行");
    return failed;
}
