# friend-setup —— sing-box 双机代理 + GitHub 订阅 + 自动换 IP

本包用于在 GCP 两台机器上搭建：

1. **sing-box 代理**（VLESS+Reality + Hysteria2，443 端口）
2. **GitHub 订阅整合**（两台机器各自推送，客户端用单一订阅 URL，永不失效）
3. **GitHub 自动换 IP**（网页 / 标记文件触发，含静态 IP 模式、清理、B 机器开关机）

**机器命名**：美西 us = A 机器，台湾 tw = B 机器。

---

## 文件说明

| 文件 | 用途 |
|---|---|
| `deploy-machine.sh` | 一键部署脚本（在 GCP 机器上运行，自包含全部组件） |
| `setup-github.sh` | 本地辅助脚本（创建仓库、推文件、配 Secrets，需 `gh` 已登录） |
| `scripts/gen-links.sh` | 从本机 sing-box 配置生成单机订阅链接 |
| `scripts/update-ip.sh` | 30 秒检测 IP 变化 → 重新生成 + 推送 |
| `scripts/merge.sh` | 合并 A+B → `links.txt` / `v2ray` / `clash.yaml`（美西执行） |
| `scripts/sync-github-a.sh` | 美西版推送（A/ 目录 + 合并产物到仓库根目录） |
| `scripts/sync-github-b.sh` | 台湾版推送（只推 B/ 目录） |
| `scripts/swap-ip.yml` | GitHub Actions 自动换 IP workflow |
| `systemd/*` | 定时器（gen-peer 30 秒 / gen-sync 5 分钟） |

---

## 阶段 0：前置准备（机主操作，约 15 分钟）

### 0.1 GCP 服务账号（自动换 IP 用）
1. 控制台 → IAM 与管理 → 服务账号 → 创建服务账号（如 `github-swap`）
2. 添加角色：
   - **Compute Instance Admin**
   - **Compute Network Admin**（换 IP 需要创建静态地址权限）
3. 密钥 → 添加密钥 → 新建 JSON → 下载（**只下载一次，保存好**）
4. 生成 Secrets 用的值：
   ```bash
   base64 -w0 <下载的json>
   ```
   把输出的**一整行**复制保存（这就是 `GCP_SERVICE_ACCOUNT_KEY`）。

### 0.2 GitHub 仓库 + Token
1. 建一个**公开**仓库，名字随机（如 `sub-cache-xxxx`）
2. 创建 PAT token（Settings → Developer settings → Tokens classic）：
   - **必须勾选 `repo` + `workflow` 两个权限**（缺 `workflow` 会导致上传 workflow 被拒）
   - 生成后复制保存

### 0.3 确认机器信息
两台 GCP 机器（美西 `us-west1` 一台、台湾 `asia-east1` 一台）已创建、可 SSH。
登录后记录实例名和区域：
```bash
hostname
curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone
```

---

## 阶段 1：部署（两条路线任选）

### 路线 A：用 setup-github.sh（推荐，需本机已登录 gh）
```bash
bash setup-github.sh sub-cache-abc123
```
脚本会自动：创建公开仓库 → 推送 `merge.sh` / `.github/workflows/swap-ip.yml` / `deploy-machine.sh` / README → 交互式配置 7 个 Secrets → 输出订阅 URL。

### 路线 B：手动（当前 gh token 无效时可用的替代方案）
1. 网页建公开仓库
2. Add file 上传：
   - `scripts/merge.sh` → 仓库根目录 `merge.sh`
   - `scripts/swap-ip.yml` → `.github/workflows/swap-ip.yml`
   - `deploy-machine.sh` → 仓库根目录
3. Settings → Secrets and variables → Actions，配置：

| Secret | 值 |
|---|---|
| `GCP_PROJECT` | GCP 项目 ID |
| `GCP_ZONE_A` | 美西区域（如 `us-west1-a`） |
| `GCP_INSTANCE_A` | 美西实例名 |
| `GCP_ZONE_B` | 台湾区域（如 `asia-east1-c`） |
| `GCP_INSTANCE_B` | 台湾实例名 |
| `GCP_SERVICE_ACCOUNT_KEY` | 阶段 0.1 的 base64 单行 |
| `SENDKEY` | Server酱 SendKey（可后配，没有则留空） |

---

## 阶段 2：在 GCP 机器上部署（每台约 10 分钟）

把 `deploy-machine.sh` 上传到机器（先美西 A，再台湾 B），以 root 执行：

```bash
# 美西机器（A）
bash deploy-machine.sh A <用户名>/<仓库名> <GH_TOKEN>

# 台湾机器（B）
bash deploy-machine.sh B <用户名>/<仓库名> <GH_TOKEN>
```

脚本会自动完成：
1. 安装依赖 + sing-box v1.13.16
2. 生成 Reality 密钥对 / UUID / Hysteria2 自签证书（10 年）
3. 写入 `config.json` 并 `sing-box check` 校验
4. 安装 `sing-box.service` 并启动
5. 安装 `gen-links.sh` / `update-ip.sh` / `sync-github.sh`（A 或 B 版本）
6. 写入 `github-sync.conf`（仓库 / token / 前缀）
7. 安装定时器：`gen-peer`（30 秒 IP 检测，两台都有）；`gen-sync`（5 分钟合并推送，仅 A）
8. 启用 BBR
9. 首次生成链接 + 推送 GitHub（失败不中断，定时器会自动重试）
10. 验证 443 监听 + Reality 握手

> 若首次推送失败，常见原因是仓库未创建 / 非公开 / token 缺 `workflow` 权限。修好后无需手动重跑：`gen-peer`（30 秒）或 `gen-sync`（A 机 5 分钟）会自动重试。

---

## 阶段 3：验证订阅

A 机合并推送后（首次部署后约 5 分钟内），浏览器/curl 访问：
```
https://raw.githubusercontent.com/<用户名>/<仓库名>/main/v2ray
```
应看到 **4 行**链接（us-vless / us-hysteria2 / tw-vless / tw-hysteria2）。

clash 订阅（可选）：`https://raw.githubusercontent.com/<用户名>/<仓库名>/main/clash.yaml`

---

## 阶段 4：自动换 IP

### 网页触发
仓库 → Actions → **swap-ip** → Run workflow → 选模式：

| 模式 | 作用 |
|---|---|
| `both` | 美西 + 台湾同时换临时 IP |
| `us` | 只换美西临时 IP |
| `tw` | 只换台湾临时 IP |
| `static-us` / `static-tw` | 新建静态 IP 并绑定（解决临时 IP 复用问题） |
| `cleanup` | 清理空闲的静态 IP（避免计费） |
| `stop-tw` / `start-tw` | 停止 / 启动台湾机器（省费用） |

### 标记文件触发（适合脚本/自动化）
向仓库根目录推送以下文件即可触发对应模式（push 触发后 workflow 会自动删除标记文件）：

| 标记文件 | 触发模式 |
|---|---|
| `.swap-trigger` | both |
| `.swap-trigger-us` | us |
| `.swap-trigger-tw` | tw |
| `.swap-trigger-static-us` | static-us |
| `.swap-trigger-static-tw` | static-tw |
| `.swap-trigger-cleanup` | cleanup |
| `.swap-trigger-stop-tw` | stop-tw |
| `.swap-trigger-start-tw` | start-tw |

换完 IP 后，机器上的 `gen-peer`（30 秒）检测到 IP 变化会自动重新生成订阅并推送，客户端**刷新订阅**即可恢复，无需手动改配置。

---

## 客户端配置

订阅 URL（客户端添加订阅）：
```
https://raw.githubusercontent.com/<用户名>/<仓库名>/main/v2ray
```

节点名：
- `us-vless` / `us-hysteria2`（美西）
- `tw-vless` / `tw-hysteria2`（台湾）

---

## 常见问题

| 问题 | 处理 |
|---|---|
| 换 IP 报 "compute.addresses.create" 权限 | 服务账号缺 **Compute Network Admin** 角色 |
| workflow 上传被拒 | token 缺 `workflow` 权限 |
| 订阅只有 2 个节点 | 台湾机器还没推送 B/ 目录，检查 gen-peer 日志 |
| B 机器换 IP 后地址没变 | GCP 临时 IP 复用，属正常；改用 `static-*` 模式 |
| 客户端连不上 | 检查 443 监听、Reality 握手验证（部署日志末尾） |
| 首次推送失败 | 仓库未创建 / 非公开 / token 权限不足；修好后定时器自动重试 |
| 想手动立即合并 | 在 A 机执行 `systemctl start gen-sync.service` 或 `/usr/local/bin/sync-github.sh` |