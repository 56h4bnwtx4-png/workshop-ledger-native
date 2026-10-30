# 车间计件 · iPadOS 原生版 v1.1.0

纯 SwiftUI 原生应用，不使用 WebView。账本保存在应用沙盒内的 SQLite 数据库，正式账单会通过 HTTPS 自动备份到阿里云，草稿始终只留在本机。

## v1.1.0 新增

- 设置页新增云端账号登录、退出、立即同步 / 重新备份
- 正式账单提交后自动上传；失败显示“待云端备份”并每 30 秒重试
- 草稿、草稿行和草稿状态不会进入上传数据或云端快照
- 支持从服务器当前数据恢复，按账单日期合并，服务器数据优先
- 支持查看最近 10 个成功快照，并将任一快照恢复到本机
- 账号、密码和登录令牌保存在系统钥匙串
- 显示最后同步时间、最近快照名称和数据版本
- 保留 v1.0.3 的“放弃草稿”触摸修复

## 现有功能

- 固定横屏，仅支持 iPad / arm64
- iPadOS 15.0 及以上
- 全部账单：正式账单与本地草稿按日期倒序合并展示
- 计件录入：客户/员工下拉、型号自由输入、历史型号本地联想、数量正整数、色数 1–5
- 草稿：按日期绑定、自动保存、后台保存、放弃草稿
- 浏览正式账单但未修改即返回时，不生成草稿
- 可修改账单日期补记过去流水
- 客户、员工档案本地增删改查，并自动备份到云端
- 原始流水、员工统计、客户统计
- 客户统计支持按日、按月、完整年度，并可按 1–5 色筛选和分类汇总
- CSV 导出：UTF-8 BOM，列中不包含提交时间
- 本机 SQLite 数据库备份导出
- 合计只统计 \`计酬工作量 = 数量 × 色数\`

## 云端接口

默认服务器：

\`\`\`text
https://ledger.893884474.xyz
\`\`\`

客户端登录类型固定为 \`ios\`，服务端返回写权限。iPad 和 Windows 共用同一个客户端账号，但 Windows 端登录类型为 \`windows\`，只能读取。

服务器端提供：

- \`POST /api/v1/auth/login\`
- \`GET /api/v1/workshop\`
- \`PUT /api/v1/workshop\`
- \`GET /api/v1/snapshots?limit=10\`
- \`GET /api/v1/snapshots/{id}/json\`
- \`GET /api/v1/snapshots/{id}/download\`

快照 JSON 接口返回解压后的完整快照，便于 iPad 直接校验并恢复；gzip 下载接口继续供 Windows 本地归档。

## 目录

\`\`\`text
WorkshopLedger/                  SwiftUI 源码、SQLite、钥匙串、云端客户端
project.yml                      XcodeGen 工程定义
.github/workflows/build-ipa.yml  GitHub Actions 无签名 IPA 构建
tools/generate_icons.py          可选的图标重新生成脚本
\`\`\`

## GitHub Actions 生成 IPA

1. 在 GitHub 新建一个仓库，或使用现有仓库。
2. 将本目录全部文件上传到仓库，默认分支使用 \`main\`。
3. 打开仓库的 **Actions** 页面，选择 **Build unsigned arm64 IPA**。
4. 点击 **Run workflow**。
5. 构建完成后，在该次运行底部下载 \`WorkshopLedger-v1.1.0-iOS-arm64-unsigned\` Artifact。
6. 解压 Artifact，得到：
   - \`WorkshopLedger-v1.1.0-iOS-arm64-unsigned.ipa\`
   - \`SHA256SUMS.txt\`
7. 将 IPA 传到 iPad，使用 TrollStore 打开并安装。

### 说明

- GitHub Actions 只负责在 macOS 运行器上编译，不会替用户上传文件到 iPad。
- 产物是无签名 arm64 IPA，专供 TrollStore 安装，不能用于 App Store。
- 删除 App 会同时删除其沙盒内的 SQLite 数据库和钥匙串登录状态。
- 云端恢复与快照恢复都属于合并恢复；同一账单日期以所选云端数据为准，本机独有账单日期保留。

## 本机验证

当前 Windows 环境没有 Xcode 和 iOS SDK，最终编译状态以 GitHub Actions 的 macOS 运行器为准。服务端接口已通过本地 9 项自动化测试及线上快照 JSON 接口联调。
