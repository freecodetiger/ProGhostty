# 签名与公证（Developer ID + Notarization）

目标：用户从 GitHub Release 下载 `.dmg` / `.zip`，双击就能开，**不出现"无法验证开发者"**，
也不需要右键→打开或 `xattr -d com.apple.quarantine`。

需要 Apple Developer Program 会员（已购买）。

---

## 为什么必须两步

1. **签名（codesign）** —— 用 `Developer ID Application` 证书签，并开启 **hardened runtime**。
   只做这一步，Gatekeeper 仍会拦：它会说"已公证"是另一回事。
2. **公证（notarize）** —— 把产物交给 Apple 扫描，换回一张 ticket，然后 **staple** 到产物上。
   staple 过的东西**离线也能通过**校验。没有 ticket 的 `.zip` 就只能靠联网查。

> **hardened runtime 是公证的硬性前提**。少了 `--options runtime`，
> `notarytool` 直接回 `The executable does not have the hardened runtime enabled`。

---

## 一次性准备（Apple 侧）

### ① Developer ID Application 证书

注意名字：**Developer ID Application**。不是 `Apple Development`（只能本机跑），
也不是 `Mac App Store`（那是商店分发）。拿错证书公证会被拒。

1. 钥匙串访问 → 证书助理 → **从证书颁发机构请求证书** → 存到磁盘（得到 `.certSigningRequest`）
2. developer.apple.com → Certificates → `+` → **Developer ID Application** → 上传 CSR
3. 下载 `.cer` → 双击装进登录钥匙串

验证：

```bash
security find-identity -v -p codesigning
# 应出现： "Developer ID Application: <名字> (TEAMID)"
```

那个 `(TEAMID)` 就是你的 Team ID。

### ② 导出成 .p12（CI 用）

钥匙串访问 → 找到 `Developer ID Application: …` → 右键 → **导出** → 存成 `.p12` → **设一个密码**。
这个密码下面要用。

```bash
base64 -i DeveloperID.p12 | pbcopy    # 粘进 GitHub secret
```

### ③ App Store Connect API Key（公证用）

直接开 <https://appstoreconnect.apple.com/access/integrations/api>，或手动走：
App Store Connect → **Users and Access** → **Integrations** → 左栏 **App Store Connect API**
→ 选 **`Team Keys`** → `+`。

- Role 选 **Developer** 即可，公证不需要 Admin
- 记下 **Key ID**，下载 **`.p8`**（**只能下载一次**）
- **Issuer ID 在该页面顶部**（UUID），Team Key 必须传

> **用 Team Keys，不要用 Individual Keys。** `notarytool --help` 写得很明确：
> `--issuer` *Required for Team API Keys. Do not provide for Individual API Keys.*
> 而 Individual Key 能否公证在 Apple 文档里没有一致说法 —— 别去试，直接用 Team Key。
>
> 若这条路线不顺，**还有一个更简单的替代**：用 Apple ID + app 专用密码，
> 完全不需要 API key（`appid.apple.com` 生成专用密码后）：
>
> ```bash
> xcrun notarytool store-credentials "ProGhostty" \
>   --apple-id "<你的 Apple ID>" --team-id "<TEAMID>"
> ```

---

## 本机构建一个已签名 + 已公证的 release

```bash
# 1) 把公证凭据存进钥匙串（只需一次；profile 名字随便取，下面保持一致）
xcrun notarytool store-credentials "ProGhostty" \
  --key ~/Downloads/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer 00000000-0000-0000-0000-000000000000

# 2) 构建
export SIGNING_IDENTITY="Developer ID Application: <名字> (TEAMID)"
export NOTARY_PROFILE="ProGhostty"
VERSION=0.2.0 BUILD=1 ./scripts/build-dmg.sh release
VERSION=0.2.0 BUILD=1 ./scripts/build-zip.sh release
```

`SIGNING_IDENTITY` **不设**时回退到 ad-hoc 签名（本地开发流程，未改动，且不允许开
hardened runtime —— 否则调试器和 Instruments 会挂不上）。ad-hoc 时**跳过公证**。

公证一次要几分钟（每个产物一次提交）。

### 验证

```bash
APP=.build/arm64-apple-macosx/release/ProGhostty.app

codesign -dv --verbose=4 "$APP"      # 期望：Authority=Developer ID Application: … / flags=0x10000(runtime)
codesign --verify --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"        # 期望：The validate action worked
spctl --assess --type exec -vvv "$APP"   # 期望：source=Notarized Developer ID

# DMG
spctl --assess --type open --context context:primary-signature -v dist/*.dmg
```

**最可靠的验证是换一台没装过证书的 Mac**，或者把产物传到另一台机器双击。

---

## CI（tag `v*` 自动出包）

`.github/workflows/release.yml` 已经接好：导入证书 → 写 API key → 构建 → 公证 → 校验。
需要在仓库 Settings → Secrets and variables → Actions 配这些：

| Secret | 内容 |
|---|---|
| `MACOS_CERTIFICATE` | `.p12` 的 **base64**（`base64 -i DeveloperID.p12 \| pbcopy`） |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设的密码 |
| `KEYCHAIN_PASSWORD` | 随便一串随机字符，CI 临时钥匙串用，用完即弃 |
| `SIGNING_IDENTITY` | `Developer ID Application: <名字> (TEAMID)` |
| `APPSTORE_API_PRIVATE_KEY` | `.p8` 文件的**原文**（不是 base64） |
| `APPSTORE_API_KEY_ID` | Key ID |
| `APPSTORE_API_ISSUER_ID` | Issuer ID（Team Key 必填；用 Apple ID 方案则不需要这个 secret） |

发版：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

> **CI 上有一个必踩的坑**：`security import` 之后如果没跑 `set-key-partition-list`，
> `codesign` 会**弹钥匙串授权框然后永久挂住**，直到 runner 超时。workflow 里已经有这一步。

---

## 公证被拒时怎么查

`scripts/notarize.sh` 在失败时会自动拉 `notarytool log` 并打印。常见原因：

| 报错 | 原因 |
|---|---|
| `does not have the hardened runtime enabled` | 签名少了 `--options runtime` |
| `does not include a secure timestamp` | 签名少了 `--timestamp` |
| `not signed with a valid Developer ID certificate` | 用了 Apple Development / 自签证书 |
| `The binary is not signed` | 嵌套二进制没签（本仓只有一个 `Contents/MacOS/pg`，脚本已先签它） |
| `A required agreement is missing` | App Store Connect 里有协议待同意 |

---

## 本仓的几个具体决定

- **不做 universal binary**：当前只出 `arm64`（CI 也是 arm64 runner）。加 Intel 需要让
  `libghostty-vt.a` 也出双架构，是独立的活。
- **不需要任何 entitlement**。app 静态链接 CoreText/Metal，自己 exec shell —— 都不受
  hardened runtime 限制。真要加的话在 `scripts/build-app-bundle.sh` 的 `codesign` 上加
  `--entitlements`。
- **不用 `--deep` 签名**。Apple 已不推荐（它会把外层的 entitlements 糊到嵌套代码上），
  公证对签错的东西零容忍。脚本改成由内向外显式签：先 `Contents/MacOS/pg`，再 bundle。
- **staging 用 `ditto` 而不是 `cp -R`**：`cp -R` 可能丢扩展属性，那会**直接破坏签名**，
  而且现象很隐蔽（本地能跑，用户下载后报"已损坏"）。
- **`.zip` 本身不签名**：未签名的压缩包不会额外触发 Gatekeeper，而里面的 `.app` 已签名
  且已 staple。
