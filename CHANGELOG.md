# Changelog / 更新记录

## v0.5.0 — Preview / 预览版

- Add an optional launcher-managed Codex Theme for the standalone Antigravity App, including Chinese localization, time-to-first-token and context metrics, and a completed compaction count.
- 公开版新增可选的 Codex Theme。Antigravity App 中可显示中文界面、首字等待、上下文占用和会话累计压缩次数。

## v0.4.0 — Preview / 预览版

- Import Clash/Mihomo subscription URLs (including Base64-wrapped YAML), read the node list, and pick a node from a dropdown; keep "auto select lowest latency" as the default. The subscription URL is stored in the Keychain and the node catalog in a private `0600` file.
- Download subscriptions with curl before starting the relay and hand the proxy core a local file provider. Downloads retry in parallel and can use a manual download proxy.
- Add `api.myip.com` and `ifconfig.me` as pinned exit-IP probes, and report a concrete hint when an auto-selected or explicitly chosen node cannot connect.
- Recover from a launcher crash/force-quit: before each start, stop orphaned proxy cores, remove their credential-bearing session directories, and free the local port; fail on an occupied port before downloading the subscription.
- Make "刷新节点" cancellable (the Stop button becomes Cancel refresh) and clear partial refresh downloads on the next launch.
- Store only a SHA-256 fingerprint of the subscription URL in the node catalog instead of the URL/token itself.
- Cache the subscription fingerprint and node configuration in one atomic record. Limit reuse to 10 minutes and require HTTPS for subscription redirects.
- Retain a named subscription node during routing reloads. Restrict orphan recovery to relay processes running from owned session directories.
- Detect and switch between the installed Antigravity editions: the launcher now lists both "Antigravity" (`com.google.antigravity`) and "Antigravity IDE" (`com.google.antigravity-ide`) with their versions in a "启动应用" picker, keeps a custom `.app` fallback, and excludes third-party helpers such as Antigravity Tools. The selection is saved with the other settings.
- Speed up connection checks: subscription downloads now race 3 concurrent curl workers with IPv4-first attempts, a successful subscription is cached for 10 minutes (private 0600 file keyed by URL fingerprint) and prefetched in the background at launch, exit-IP checks run the 4 probes concurrently, and the status line reports elapsed time. Local measurements: first check ≈5 s, cached checks ≈2–3 s (previously tens of seconds per click).
- UI refresh: the connection status text now spans the full panel width instead of being squeezed into a narrow column; a segmented source switch, visible subscription URL, inline node picker + refresh button, larger action buttons, clearer status icon (success/error) and a stable default window size improve readability and reduce clicks.

- 支持导入 Clash/Mihomo 订阅链接（含 Base64 编码的 YAML），读取节点后可在“节点”下拉框中快捷选择；默认“自动选择延迟最低”。订阅地址保存在钥匙串，节点名称列表保存在权限 `0600` 的私有文件。
- 订阅由本工具使用 curl 下载，再以本地文件交给内核。下载支持并发重试，也可以指定手动代理。
- 出口检测新增 `api.myip.com` 和 `ifconfig.me`；自动选择或指定节点无法连通时给出更具体的提示。
- 崩溃或强制退出后可自愈：每次启动前结束遗留的内核进程、删除含凭据的残留临时配置并释放端口；端口被占用时在下载订阅之前就报错。
- “刷新节点”可取消（停止按钮会变成“取消刷新”），下次启动清理未完成的下载临时目录。
- 节点目录只保存订阅地址的 SHA-256 指纹，不再把订阅地址/令牌写入磁盘。
- 订阅缓存将地址指纹和节点配置一次写入，仅复用 10 分钟内的记录。订阅重定向要求使用 HTTPS。
- 运行中重载分流时保留指定节点。异常退出恢复仅清理来自本工具专用会话目录的转发进程。
- 支持 Antigravity 双版本：自动检测并列出已安装的“Antigravity”（`com.google.antigravity`）与“Antigravity IDE”（`com.google.antigravity-ide`）及版本号，可在“启动应用”下拉框切换，也保留“选择…”自定义 `.app`；不会把 Antigravity Tools 等第三方工具当作启动目标。选择会随设置保存。
- 提速连接检查：订阅下载改为 3 路并发并优先 IPv4，成功后缓存 10 分钟（私有 0600 文件、按地址指纹校验），启动时后台预取；出口 IP 的 4 个地址并发探测，状态里显示耗时。本机实测首次约 5 秒、缓存后约 2–3 秒（此前每次点击常需数十秒）。
- 界面优化：连接状态文案改为整行显示，不再被挤成窄条；代理来源改为分段切换，订阅地址可见，节点选择与“刷新节点”同行，操作按钮加大，状态图标区分成功/失败，默认窗口尺寸更适合单屏查看。

## v0.3.0 — Preview / 预览版

- Validate and reload direct-domain rules while Antigravity runs through the launcher. Save the updated lists for subsequent launches and apply the new rules to subsequent connections.
- Antigravity 运行期间可验证并重载直连域名规则。更新后的名单会保存，新规则用于后续连接。

## v0.2.0 — Preview / 预览版

- Add advanced settings for exact direct domains (`directDomains`) and direct domain suffixes (`directDomainSuffixes`), both empty by default. Accept comma or whitespace separated entries; reject direct entries for known model service domains.
- Reject UDP in the local relay, keep exit-check domains on `UPSTREAM`, route explicitly configured domains to `DIRECT`, and send remaining requests to `UPSTREAM` without a direct fallback.
- Apply saved settings on the next launch; no live reload, system proxy changes, TUN, or continuous exit-IP monitoring.
- Document company DNS/VPN/SSO prerequisites, proxy-aware tool coverage, and the separate paths for retrieving internal content and sending it to a model service. Keep existing local route checks distinct from validation of the public Swift build.

- 高级设置新增精确直连域名和直连域名后缀，默认均为空，支持逗号或空白分隔；拒绝已知模型服务域名的直连配置。
- 本地转发拒绝 UDP，出口检测域名固定走上游；仅明确配置的域名直连，其余请求走上游，不提供直连回退。
- 保存后下次启动生效，不支持热更新；不修改系统代理、不启用 TUN、不持续监测出口 IP。
- 补充公司 DNS、VPN、SSO 前提、工具遵循代理的范围，以及内网取数和向模型发送内容的两条路径；分别记录既有本机分流验证与公开 Swift 构建验证。
