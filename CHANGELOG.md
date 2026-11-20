# Changelog / 更新记录

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
