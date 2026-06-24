# DeepSeno iOS GitHub Actions Release

这个仓库现在可以通过 `.github/workflows/ios-release.yml` 在 GitHub Actions 里手动打包 iOS 正式包，并上传到 App Store Connect / TestFlight。运行时需要填写的字段和 Android workflow 保持一致：`version` 和 `prerelease`。

## 需要配置的 GitHub Secrets

在 GitHub 仓库页面进入 `Settings` -> `Secrets and variables` -> `Actions` -> `New repository secret`，添加下面这些 secret。

| Secret 名称 | 作用 | 来源 |
| --- | --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key 的 Key ID。workflow 会写入 `.env` 的 `Key ID=`，并传给 `xcodebuild` / `altool`。 | App Store Connect -> Users and Access -> Integrations -> App Store Connect API |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API 的 Issuer ID。workflow 会写入 `.env` 的 `Issuer ID=`，用于签发 JWT 和 Apple API 认证。 | 同一个 API key 页面上的 Issuer ID |
| `APPLE_TEAM_ID` | Apple Developer Team ID。workflow 会写入 `.env` 的 `Team ID=`，用于 Xcode 自动签名和导出 IPA。 | Apple Developer 账号的 Membership details |
| `APP_BUNDLE_ID` | iOS Bundle ID。workflow 会写入 `.env` 的 `Bundle ID=`，并用于 Xcode 构建和 App Store Connect 查询。 | App Store Connect 中对应 App 的 Bundle ID |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | `.p8` 私钥的 base64 内容。workflow 会写入 `.env` 的 `Private Key Base64=`，并解码成 `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`。 | 下载的 `AuthKey_<KEY_ID>.p8` 文件 |
| `RELAY_SERVER_BASE_URL` | 可选。生产 relay 服务地址，例如 `https://relay.example.com/api/v1`。不配置则 App relay mode 为空，仍可使用局域网配对。 | 你的部署环境 |

私钥 base64 在 macOS 上这样生成：

```bash
base64 -i ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 | tr -d '\n'
```

把输出的整行内容填到 `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`。这个值是敏感密钥，不要提交到仓库。

## App Store Connect 权限

这个 API key 需要有 `Admin` 权限。发布脚本依赖 Xcode 的 cloud-managed signing，`App Manager` / `Developer` 权限通常不够。

## 触发发布

进入 GitHub Actions，选择 `Build iOS IPA`，点击 `Run workflow`。

常用输入：

| 输入 | 说明 |
| --- | --- |
| `version` | 用户看到的版本号，比如 `1.5.2`。workflow 会写入 `project.yml` 的 `MARKETING_VERSION`。 |
| `prerelease` | 和 Android workflow 一样表示测试版。`true` 时只上传 TestFlight；`false` 时上传后等待 App Store Connect 处理完成，并提交 App Store 审核。 |

## 本地 `.env`

本地发布可以复制 `.env.example`：

```bash
cp .env.example .env
```

然后填入：

```env
Key ID=...
Issuer ID=...
Team ID=...
Bundle ID=...
Relay Server Base URL=
Private Key Base64=...
```

如果本机已经有 `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`，`Private Key Base64` 可以不填；GitHub Actions 里必须配置对应 secret。

## 注意事项

- workflow 不会提交版本号修改到仓库，只在本次 CI runner 里临时改 `project.yml`。
- `CURRENT_PROJECT_VERSION` / `CFBundleVersion` 不需要手动填写，workflow 会用 UTC 时间自动生成，例如 `20260625081230`。
- `prerelease=false` 会提交 App Store 审核，使用 `scripts/asc-release.mjs` 里的默认 App Store 更新说明；如需改文案，先改脚本中的 `WHATS_NEW`。
- TestFlight 上传后 Apple 通常需要 10-30 分钟处理；workflow 最多等待 30 分钟。如果超时，说明 App Store Connect 还没把 build 标记为 `VALID`，稍后重新运行即可。
- workflow 会上传导出的 `DeepSeno.ipa` 到 GitHub Actions artifact，方便下载留档。
