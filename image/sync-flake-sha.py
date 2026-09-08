#!/usr/bin/env python3
# 从 dist/SHA256SUMS 同步 nixos-modules/assets.nix 的 release tag 与各资产 sha256
# 用法：python3 image/sync-flake-sha.py <SHA256SUMS> <assets.nix> <release-tag>
#
# SHA256SUMS 驱动：遍历全部条目，对 assets.nix 中 url 以该资产名结尾的
# sha256 行做锚定替换——新增发行版时只需 SHA256SUMS 多一个条目（模块内
# 已有对应 osAssets 行则自动同步；否则警告提示补行）。
# 幂等：值相同则文件不变（git diff 为空，调用方跳过提交）。
import re
import sys

sha_file, nix_file, tag = sys.argv[1], sys.argv[2], sys.argv[3]

shas = {}
for line in open(sha_file):
    parts = line.split()
    if len(parts) == 2:
        shas[parts[1]] = parts[0]

# release 里有但消费端不 fetch 的资产：不该产生「缺对应行」的警告，否则真正
# 需要补行的新发行版会被噪声淹没。config-router 是自建内核的 .config，供人工
# 查阅与复现构建（版本串、开了哪些符号），router.nix 不引用它。
NOT_FETCHED = {"config-router"}

s = open(nix_file).read()

# 更新 tag（幂等：同日重跑值不变）
s, n_tag = re.subn(r'imageRelease = "[^"]*";', f'imageRelease = "{tag}";', s, count=1)
if n_tag == 0:
    sys.exit("imageRelease 行未找到")

updated = 0
for asset, sha in sorted(shas.items()):
    # 锚定 url 以该资产名结尾的 sha256 行
    pattern = re.compile(
        r'(url = "[^"]*/' + re.escape(asset) + r'";\n(?:\s*#[^\n]*\n)*\s*sha256 = ")[0-9a-f]{64}(")'
    )
    s, n = pattern.subn(r"\g<1>" + sha + r"\g<2>", s, count=1)
    if n == 0:
        if asset in NOT_FETCHED:
            print(f"跳过 {asset}（消费端不 fetch，仅供人工查阅）")
        else:
            print(f"⚠️ SHA256SUMS 有 {asset}，但 router.nix 无对应资产行（新发行版需在 osAssets 补行）")
    else:
        updated += 1
        print(f"已同步 {asset}: {sha[:12]}...")

if updated == 0:
    sys.exit("没有任何资产条目被同步，检查 SHA256SUMS 与 router.nix 的对应关系")

open(nix_file, "w").write(s)
print(f"完成：tag={tag}，同步 {updated} 个资产")
