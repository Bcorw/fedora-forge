# Fedora Forge

> 面向 **全新安装的 Fedora 44+ KDE Plasma** 的一键初始化脚本。
> 软件源优化、驱动安装、终端美化、常用软件，一次跑完；支持重复执行（幂等）。

![Fedora](https://img.shields.io/badge/Fedora-44+-51A2DA?logo=fedora&logoColor=white)
![KDE](https://img.shields.io/badge/KDE-Plasma-1D99F3?logo=kde)
![License](https://img.shields.io/badge/License-个人使用-lightgrey)

所有模块均已在真机（NVIDIA/AMD 混合笔记本）验证，开箱即用。

---

## 📥 仓库使用说明

### 方式一：直接克隆

```bash
git clone https://github.com/Bcorw/fedora-forge.git
cd fedora-forge
sudo bash fedora-forge.sh
```

### 方式二：下载 ZIP

GitHub 页面 → **Code** → **Download ZIP** → 解压后进入目录执行。

> 推荐克隆方式，方便日后 `git pull` 获取更新。

---

## 🚀 使用方法

```bash
# 查看帮助
sudo bash fedora-forge.sh -h

# 一键执行核心模块（1-6）：软件源 / 升级 / 驱动 / 终端 / 主题 / 应用
sudo bash fedora-forge.sh

# 包含 Steam 的全部模块
sudo bash fedora-forge.sh -all

# 只执行指定模块
sudo bash fedora-forge.sh -source        # 软件源
sudo bash fedora-forge.sh -gpu -theme    # 驱动 + 主题
sudo bash fedora-forge.sh -apps          # 应用管理

# 跳过系统升级检查（系统刚升级过时）
sudo bash fedora-forge.sh -no-upgrade

# 测试模式（无需 root，演练流程，不实际安装/重启）
sudo bash fedora-forge.sh -apps -test
```

**注意**：
- 必须以 `sudo` 运行
- 请在项目根目录内执行（脚本依赖同目录资源）
- 首次运行会自动全量升级 + 安装，耗时较长，请保持网络稳定
- 执行完会提示**手动重启**（不自动重启）

---

## ✨ 功能总览

| 模块 | 说明 |
|------|------|
| 1. 软件源优化 | 8 个国内镜像并发测速 → 最快 mirrorlist；RPM Fusion / Flathub；DNF 并发优化；开机自启刷新 |
| 2. 系统升级检查 | 内核模块完整性校验 + 全量升级 + 内核升级后提示重启 |
| 3. CPU/GPU 驱动 | 自动识别 NVIDIA / AMD，按需安装；`auto-cpufreq` 电源管理（仅笔记本）；ffmpeg 完整解码 |
| 4. 终端配置 | 中文字体；Zsh + Starship + Zinit（fzf-tab / 高亮 / 建议）；Konsole / Kitty 美化 |
| 5. 主题 & 系统 | Breeze 主题；登录背景；SELinux Permissive；NetworkManager 优化；CyberGRUB-2077；启动项精简标题 |
| 6. 应用管理 | 卸载 KDE 预装应用（可选）；Fcitx5 雾凇 + 万象语法模型、Chrome、VSCode、QQ、微信、Office、KVM 等 |
| 7. 32 位库 & Steam（可选） | 32 位兼容库 + Steam |

---

## 📁 项目结构

```
fedora-forge/
├── fedora-forge.sh              # 主脚本（唯一入口）
├── fcitx5/                      # Rime 雾凇配置
│   ├── default.yaml             #   方案列表（小鹤 / 雾凇全拼 / 自然码）
│   └── *.custom.yaml            #   各方案补丁（全拼提示 + 万象语法模型）
├── konsole/                     # Konsole 终端方案（配色 / 配置 / starship 主题）
├── fonts/                       # 字体资源包（tar.gz，脚本自动解压安装）
├── wallpapers/                  # 壁纸（登录背景等）
└── README.md
```

> **kitty / CyberGRUB 主题**：脚本运行时自动从 GitHub 在线获取，无需随仓库携带：
> - Kitty 方案：[Sidharth7082/kitty](https://github.com/Sidharth7082/kitty)
> - GRUB 主题：[adnksharp/CyberGRUB-2077](https://github.com/adnksharp/CyberGRUB-2077)

---

## 🧩 模块详情

### 1. 软件源优化
- 并发测速 8 个国内镜像（TUNA / USTC / SJTU / Aliyun 等），写入 `mirrorlist`
- 安装 RPM Fusion（free + nonfree）并接入镜像
- 优化 `/etc/dnf/dnf.conf`（`max_parallel_downloads` / `keepcache` / `defaultyes` 等）
- 生成开机自启刷新脚本 `~/.local/scripts/source-optimize.sh`

### 2. 系统升级检查
- 校验运行内核模块完整性，缺失自动补装（防声卡/网卡驱动丢失）
- 自动全量升级（`--no-upgrade` 跳过）
- 检测到内核更新 → 提示重启后重跑（第二次自动跳过，幂等）

### 3. CPU/GPU 驱动
- `lspci` 自动识别 NVIDIA / AMD：
  - **NVIDIA**：akmod 驱动 + CUDA + Secure Boot 检测（提示导入 MOK 密钥）
  - **AMD**：Mesa + Vulkan + amdgpu
  - 自动清理非本机 GPU 的孤包（如 AMD 机上的 Intel/NVIDIA 驱动）
- `auto-cpufreq` 电源管理（仅检测到电池时安装；服务已运行则跳过）
- 音视频解码：`ffmpeg`（自动处理与 `ffmpeg-free` 的冲突）+ gstreamer 全家桶
- 幂等：驱动版本号存在即跳过安装/编译

### 4. 终端配置
- 字体：`fonts/` 压缩包自动解压安装（HarmonyOS Sans / 霞鹜文楷 / Maple Mono NF CN）
- **Zsh**：Zinit 插件管理器 + fzf-tab（Tab 补全 + eza 预览）+ 语法高亮 + 自动建议 + zoxide
- **Starship**：项目 `konsole/starship.toml` 部署
- **Konsole**：项目 `konsole/` 方案（Catppuccin Frappe + MapleMono + 复制选中/中键粘贴）
- **Kitty**：自动从 GitHub 获取（170+ 主题 + rofi 切换器 `~/.config/kitty/kitty-theme.sh`）

### 5. 主题 & 系统
- Breeze 主题还原 + 第三方主题安全清理（白名单保护，防黑屏）
- 登录背景、SELinux → Permissive、固件检查（7 天内刷新过则跳过）
- NetworkManager：禁用 wait-online + 连通性检测
- GRUB：CyberGRUB-2077 主题（在线获取）+ 30s 菜单 + 启动项标题精简（内核升级后自动保持）
- `fstrim.timer` 开启

### 6. 应用管理
- **卸载**：KDE 预装应用清单扫描，询问确认（60s 无输入默认卸载，输 `n` 跳过）
- **安装**：
  - dnf：Fcitx5 + Rime 雾凇、Node.js、VSCode、Chrome、KVM/QEMU 等
  - RPM：QQ、微信、ONLYOFFICE、Gopeed、VutronMusic 等（**GitHub 自动解析最新版本**）
  - Flatpak：Typora、LocalSend、Gear Lever、Mission Center、PinApp（逐个安装，已装跳过）
  - opencode：官方脚本（失败自动转桌面端 RPM）
- **Rime 雾凇**：拉取 `rime-ice` 后应用项目 `fcitx5/` 配置——三方案（小鹤双拼 / 雾凇全拼 / 自然码）、全拼提示、**万象语法模型**（缺失自动下载）

### 7. 32 位库 & Steam
安装 32 位兼容库（只装缺失的）与 Steam。

---

## ⚙️ 其他特性

- **幂等**：重复运行安全，已安装/已配置项全部自动跳过
- **日志**：全程写入 `/var/log/fedora-forge.log`
- **版本检查**：仅支持 Fedora 42-44（44 为本年度稳定版）
- **网络检测**：启动前检查网络，不可用时明确报错
- **测试模式**：`-test`，无需 root，演练流程不实际改动系统
- **重启提醒**：执行完提示手动重启（不自动重启）
- **安全**：无任何网络回传，纯本地执行

---

## ❓ 常见问题

**Q1：第一次运行要多久？**
首次运行包含全量升级 + 驱动编译 + 软件安装，约 30-60 分钟（取决于网速）。后续重跑秒级跳过已装项。

**Q2：内核升级后提示重启，重启后还要再跑吗？**
需要。重启后再次运行脚本即可（会自动跳过已完成的升级和安装）。

**Q3：`-test` 模式是干什么的？**
不需要 root 的演练模式：走完整流程但不实际安装/修改系统，适合先看脚本会做什么。

**Q4：字体/壁纸可以不下载吗？**
`fonts/`（约 190MB）与 `wallpapers/`（约 50MB）随仓库携带；若只需脚本，可删除这两个目录，脚本会跳过并提示。

**Q5：输入法怎么用？**
安装后 Fcitx5 默认启用，切换小鹤/全拼/自然码方案用 F4；候选翻页键为 `-` / `=`。

**Q6：Kitty / GRUB 主题获取失败？**
脚本会自动从 GitHub 克隆；网络受限时可手动：
```bash
git clone https://github.com/Sidharth7082/kitty /tmp/kitty-style
git clone https://github.com/adnksharp/CyberGRUB-2077 /tmp/cybergrub
```

---

## 📋 运行后验证

| 项目 | 命令 |
|------|------|
| NVIDIA 驱动 | `nvidia-smi` |
| 电源管理 | `tail -f /var/run/auto-cpufreq.stats` |
| 输入法 | 打开输入框切换 Fcitx5（小鹤 `-` `=` 翻页） |
| 虚拟化 | `virt-manager` |
| SELinux | `getenforce`（应为 Permissive） |
| 日志 | `tail -f /var/log/fedora-forge.log` |

---

## 📄 License

本项目仅供学习使用；第三方软件（NVIDIA、RPM Fusion、字体、主题等）版权归各自作者所有。
