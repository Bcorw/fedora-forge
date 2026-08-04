#!/bin/bash
# ============================================================================
#  Fedora Forge — Fedora 44+ 全面初始化 & 优化脚本 v4.3
#  (dnf5 / KDE Plasma)
#  ---------------------------------------------------------------------------
#  模块:
#    1. 软件源优化   — 多站并发测速 + RPM Fusion + Flathub + 开机自启
#    2. 系统升级检查 — 仅全量运行(-all/无参数)时执行; 单模块执行自动跳过
#    3. CPU/GPU驱动  — 自动识别 NVIDIA/AMD/Intel (厂商ID), 安装对应驱动+配套解码
#                    — NVIDIA 固定生产版 595.80 (open 模块, 默认钉死; FF_NV_VERSION 可换)
#                    — 电源管理: 默认官方方案; 笔记本询问是否装 auto-cpufreq
#                    — 装 auto-cpufreq 时生成回退官方方案脚本 (~/.local/scripts/power-official.sh)
#                    — 音视频解码
#    4. 终端配置     — 字体 + Zsh/Starship/Zinit + Konsole/Kitty
#    5. 主题&系统    — Breeze主题 + 登录背景 + SELinux + GRUB
#                    — NetworkManager优化 (wait-online + 连通性检测)
#                    — GRUB 显示菜单30s + CyberGRUB-2077 + 启动项标题=系统名+内核版本
#    6. 应用管理     — 清单扫描卸载(60s默认确认) + 批量安装 + KVM/QEMU
#                    — Flatpak 逐个安装 + MissionCenter 依赖/中文环境
#    7. 32位库&Steam — (可选) 32位兼容库 + Steam
#
#  用法:
#    sudo bash fedora-forge.sh                # 执行 1-6 核心模块
#    sudo bash fedora-forge.sh -steam       # 额外执行 Steam 模块
#    sudo bash fedora-forge.sh -source -gpu # 只执行指定模块
#    sudo bash fedora-forge.sh -all         # 执行全部模块(含 Steam)
#    sudo bash fedora-forge.sh -h           # 帮助
#  未知模块名将直接报错退出, 不会自动执行
#  所有 GitHub 连接直连失败后自动走 https://gh-proxy.com/ 镜像
# ============================================================================
set -uo pipefail

# ────────────────────────────────────────────── 颜色 & 日志
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}${BOLD}▶ $*${NC}"; echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
warn()  { echo -e "${YELLOW}[注意]${NC}  $*"; }
error() { echo -e "${RED}[错误]${NC} $*"; }
die()   { error "$1"; exit 1; }

# ────────────────────────────────────────────── GitHub 加速通道 (gh-proxy.com)
# 国内网络直连 GitHub 不稳定 (clone/API/下载均可能失败):
# 所有 GitHub 操作先直连, 失败后自动走 https://gh-proxy.com/ 镜像重试
GHPROXY="https://gh-proxy.com/"

# gh_clone <仓库路径 user/repo> <目标目录> — git clone 带镜像回退
gh_clone() {
    local repo="$1" dir="$2"
    if git clone --depth=1 "https://github.com/${repo}" "$dir" >/dev/null 2>&1; then
        return 0
    fi
    info "GitHub 直连失败, 走 gh-proxy.com 镜像克隆 ${repo}..."
    git clone --depth=1 "${GHPROXY}https://github.com/${repo}" "$dir" >/dev/null 2>&1
}

# gh_curl <URL> [curl附加参数...] — curl 带镜像回退, 结果输出到 stdout
#   用法: gh_curl "URL" --connect-timeout 10 | grep ...    (取数据)
#         gh_curl "URL" > /tmp/file.tar.gz                  (下载文件)
gh_curl() {
    local url="$1"; shift
    local tmp; tmp=$(mktemp)
    if curl -fL --retry 2 "$@" "$url" -o "$tmp" >/dev/null 2>&1; then
        cat "$tmp"; rm -f "$tmp"; return 0
    fi
    info "GitHub 直连失败, 走 gh-proxy.com 镜像: ${url}"
    if curl -fL --retry 2 "$@" "${GHPROXY}${url}" -o "$tmp" >/dev/null 2>&1; then
        cat "$tmp"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

# ────────────────────────────────────────────── 参数解析
RUN_SOURCE=0; RUN_GPU=0; RUN_TERM=0; RUN_THEME=0; RUN_APPS=0; RUN_STEAM=0
RUN_UPGRADE=1
# 电源管理方案: ask=交互选择(默认, 笔记本询问) / auto=auto-cpufreq / default=系统默认(官方)
POWER_MODE="${FF_POWER:-ask}"
HAS_MODULE=0
RUN_ALL=0

# 测试模式: 仅验证流程与配置落盘, 不执行真实 dnf/flatpak/重启 (防误伤真实系统)
TEST_MODE="${FF_TEST:-0}"
if [[ "$*" == *"-test"* ]]; then TEST_MODE=1; fi

for arg in "$@"; do
    case "$arg" in
        -source)  RUN_SOURCE=1; HAS_MODULE=1 ;;
        -gpu)     RUN_GPU=1;    HAS_MODULE=1 ;;
        -term)    RUN_TERM=1;   HAS_MODULE=1 ;;
        -theme)   RUN_THEME=1;  HAS_MODULE=1 ;;
        -apps)    RUN_APPS=1;   HAS_MODULE=1 ;;
        -steam)   RUN_STEAM=1;  HAS_MODULE=1 ;;
        -no-upgrade) RUN_UPGRADE=0 ;;
        -power=*)  POWER_MODE="${arg#-power=}" ;;
        -test)    : ;; # 已在上面启用 TEST_MODE
        -all)
            RUN_SOURCE=1; RUN_GPU=1; RUN_TERM=1
            RUN_THEME=1; RUN_APPS=1; RUN_STEAM=1; HAS_MODULE=1; RUN_ALL=1 ;;
        -h|-help|--help)
            echo "用法: sudo bash $0 [模块...]"
            echo ""
            echo "模块 (可组合, 无参数=执行 1-6 核心模块):"
            echo "  -source   软件源优化"
            echo "  -gpu      CPU/GPU驱动(自动识别, NVIDIA固定595.80) + 电源方案 + 解码"
            echo "            环境变量: FF_NV_VERSION=595.xx 换NVIDIA版本; FF_POWER=auto|default 免交互"
            echo "  -term     终端配置 (字体 + Zsh/Starship/Zinit + Konsole/Kitty)"
            echo "  -theme    主题 & 系统优化 (含 NetworkManager 优化)"
            echo "  -apps     应用管理 (卸载 + 安装)"
            echo "  -steam    (可选) 32位库 + Steam"
            echo "  -all      执行全部模块 (含 Steam)"
            echo "  -test     测试模式: 不装包、不重启, 仅验证流程"
            echo "  -no-upgrade 跳过系统升级检查 (默认自动升级)"
            echo "  -power=auto|default  电源方案: 系统默认(官方) / auto-cpufreq"
            exit 0 ;;
        *) die "未知模块/参数: $arg (用 -h 查看可用模块, 未指定模块时将执行核心模块)" ;;
    esac
done

# 测试模式下覆盖包管理/重启为无害行为 (防止误重启真实系统)
# ⚠ 必须放在函数定义之后 (见脚本末尾), 否则会被后续定义覆盖

# 默认不执行 -steam，仅执行核心模块
[[ "$HAS_MODULE" -eq 0 ]] && { RUN_SOURCE=1; RUN_GPU=1; RUN_TERM=1; RUN_THEME=1; RUN_APPS=1; }

# ────────────────────────────────────────────── 权限 & 环境检测
# 测试模式 (-test) 是只读演练, 所有写操作已被拦截, 无需真实 root
if [[ "$TEST_MODE" -eq 0 ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "请用 sudo 运行: sudo $0"
fi
ACTUAL_USER="${SUDO_USER:-$(whoami)}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)
[[ -n "$ACTUAL_HOME" ]] || ACTUAL_HOME="/home/$ACTUAL_USER"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES_DIR="${SCRIPT_DIR}"
DNF="$(command -v dnf5 2>/dev/null || command -v dnf 2>/dev/null || echo dnf)"
FEDORA_VER=$(rpm -E %fedora 2>/dev/null || echo 42)
BASEARCH=$(rpm -E %_arch 2>/dev/null || echo x86_64)

# 基础工具自装 (全新系统可能缺失 git/curl, 直接装而不是报错退出)
for _tool in curl git; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        warn "缺少 $_tool, 自动安装..."
        timeout 300 "$DNF" install -y "$_tool" >/dev/null 2>&1 || \
            die "$_tool 安装失败, 请检查网络后重试"
    fi
done
unset _tool

# 个人脚本目录
SCRIPTS_DIR="${ACTUAL_HOME}/.local/scripts"
mkdir -p "$SCRIPTS_DIR"

info "用户: ${BOLD}$ACTUAL_USER${NC}  系统: ${BOLD}Fedora $FEDORA_VER${NC} ($BASEARCH)  包管理器: $(basename "$DNF")"

# ────────────────────────────────────────────── 辅助函数
# 轻量级等待 RPM 锁 (最长约 30 秒)
wait_rpm() {
    local rounds=0
    while pidof dnf dnf5 packagekitd >/dev/null 2>&1; do
        (( rounds++ >= 10 )) && break
        sleep 3
    done
}

# 批量安装 (合并为一次 dnf 调用)
dnf_install() {
    wait_rpm
    "$DNF" install -y --skip-unavailable "$@" 2>/dev/null
}

# 批量安装 (静默)
dnf_install_quiet() {
    wait_rpm
    "$DNF" install -y --skip-unavailable "$@" >/dev/null 2>&1
}

# 依赖容错安装: 只安装缺失的包, 批量失败后逐包重试, 全程不中断脚本
#   用法: dnf_ensure <包名...>
dnf_ensure() {
    local missing=() pkg
    for pkg in "$@"; do
        if [[ "$pkg" == @* ]]; then
            # 组包: rpm -q 查不了, 用 dnf group list --installed 判断
            dnf group list --installed 2>/dev/null | grep -qi "${pkg#@}" || missing+=("$pkg")
        else
            rpm -q "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        info "依赖检查: $* 均已安装"
        return 0
    fi

    info "依赖检查: 缺少 ${missing[*]}, 开始安装..."
    wait_rpm
    if timeout 900 "$DNF" install -y --skip-unavailable "${missing[@]}" >/dev/null 2>&1; then
        # dnf5 对不存在的包会静默跳过并返回 0, 必须逐个复查 (@ 组无法用 rpm -q 验证)
        local still_missing=() pkg
        for pkg in "${missing[@]}"; do
            [[ "$pkg" == @* ]] && continue
            rpm -q "$pkg" >/dev/null 2>&1 || command -v "$pkg" >/dev/null 2>&1 || still_missing+=("$pkg")
        done
        if [[ ${#still_missing[@]} -eq 0 ]]; then
            info "✅ 依赖安装完成: ${missing[*]}"
            return 0
        fi
        warn "部分包未就绪 (${still_missing[*]}), 改为逐包安装..."
        missing=("${still_missing[@]}")
    else
        warn "批量安装失败, 改为逐包安装..."
    fi

    local fail_count=0 pkg
    for pkg in "${missing[@]}"; do
        wait_rpm
        if timeout 900 "$DNF" install -y "$pkg" >/dev/null 2>&1; then
            if [[ "$pkg" == @* ]] || rpm -q "$pkg" >/dev/null 2>&1 || command -v "$pkg" >/dev/null 2>&1; then
                info "  ✅ $pkg 安装成功"
            else
                warn "  ❌ $pkg 未就绪 (包名可能不存在, 已跳过)"
                ((fail_count++))
            fi
        else
            warn "  ❌ $pkg 安装失败 (已跳过, 不影响后续流程)"
            ((fail_count++))
        fi
    done
    [[ "$fail_count" -eq 0 ]] && info "✅ 依赖全部安装完成"
    return 0
}

# ────────────────────────────────────────────── 日志
# 所有输出同时写入日志文件, 便于排错与反馈
LOGFILE=/var/log/fedora-forge.log
exec > >(tee -a "$LOGFILE") 2>&1
info "===== Fedora Forge 运行开始: $(date '+%Y-%m-%d %H:%M:%S') ====="

# 并发测速 (缩短超时)
#   用法: speedtest_mirrors <test_path> <镜像池数组名>
#   结果写入全局数组 SPEEDTEST_RESULTS=( "url|ms|name" ... )
speedtest_mirrors() {
    local test_path="$1"
    local -n _POOL_REF="$2"
    SPEEDTEST_RESULTS=()

    info "正在对 ${#_POOL_REF[@]} 个镜像站并发测速..."
    local tmp_dir pids=()
    tmp_dir=$(mktemp -d)

    for name in "${!_POOL_REF[@]}"; do
        local url="${_POOL_REF[$name]}${test_path}"
        (
            local start_time end_time elapsed
            start_time=$(date +%s%N)
            if curl -sf --connect-timeout 2 --max-time 5 -o /dev/null "$url" 2>/dev/null; then
                end_time=$(date +%s%N)
                elapsed=$(( (end_time - start_time) / 1000000 ))
                echo "${elapsed} ${name}" > "${tmp_dir}/${name}.result"
            else
                echo "99999 ${name}" > "${tmp_dir}/${name}.result"
            fi
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    local sorted_results=""
    for f in "${tmp_dir}"/*.result; do
        [[ -f "$f" ]] && sorted_results+="$(cat "$f")"$'\n'
    done
    rm -rf "$tmp_dir"

    sorted_results=$(echo "$sorted_results" | sort -n)
    echo -e "  ────────────────────────────────────"
    local rank=1
    while IFS=' ' read -r ms name; do
        [[ -z "$name" ]] && continue
        if [[ "$ms" -ge 99999 ]]; then
            printf "  #%-2d  %-10s  %s\n" "$rank" "$name" "${RED}超时${NC}"
        else
            printf "  #%-2d  %-10s  ${GREEN}%4d ms${NC}\n" "$rank" "$name" "$ms"
        fi
        SPEEDTEST_RESULTS+=("${_POOL_REF[$name]}|$ms|$name")
        ((rank++))
    done <<< "$sorted_results"
    echo -e "  ────────────────────────────────────"
}

# 从测速结果中选出最快可达的镜像
pick_fastest_mirror() {
    for entry in "${SPEEDTEST_RESULTS[@]}"; do
        IFS='|' read -r url ms name <<< "$entry"
        if [[ "$ms" -lt 99999 ]]; then
            printf '%s\n' "$url"
            return 0
        fi
    done
    return 1
}

# 生成 mirrorlist 文件
generate_mirrorlist() {
    local output_file="$1"
    local url_suffix="$2"
    > "$output_file"
    local count=0
    for entry in "${SPEEDTEST_RESULTS[@]}"; do
        IFS='|' read -r url ms name <<< "$entry"
        if [[ "$ms" -lt 99999 ]]; then
            echo "${url}${url_suffix}" >> "$output_file"
            ((count++))
        fi
    done
    [[ $count -eq 0 ]] && { warn "无可用镜像站: $output_file"; return 1; }
    info "已生成 mirrorlist: $(basename "$output_file") ($count 个源)"
    return 0
}

# 下载并直接安装单个 RPM
install_direct_rpm() {
    local url="$1" name="$2" pkg="$3"
    # 已安装则跳过 (避免二次执行 -apps 时重复下载重装)
    if [[ -n "$pkg" ]] && rpm -q "$pkg" >/dev/null 2>&1; then
        info "  $name: 已安装, 跳过"
        return 0
    fi
    info "安装 $name..."
    if curl -fsSL --retry 2 --connect-timeout 20 -o "/tmp/${name}.rpm" "$url" 2>/dev/null && \
       "$DNF" install -y --skip-broken "/tmp/${name}.rpm" >/dev/null 2>&1; then
        info "  ✅ $name 安装完成"
    else
        warn "$name 安装失败"
    fi
    rm -f "/tmp/${name}.rpm"
}

# 从 GitHub latest release 自动解析并安装 RPM (不写死版本号)
#   用法: install_github_rpm <仓库owner/repo> <显示名> <rpm包名> <资产匹配正则>
#   例:   install_github_rpm "GopeedLab/gopeed" "Gopeed" "gopeed" "linux-amd64.*\.rpm$"
# 网络通道: 优先 api.github.com (拿 JSON); 不可达时回退 github.com/releases/
# expanded_assets 页面 (实测部分网络 api.github.com 403 而 github.com 正常)
install_github_rpm() {
    local repo="$1" name="$2" pkg="$3" pattern="$4"
    # 已安装则跳过
    if [[ -n "$pkg" ]] && rpm -q "$pkg" >/dev/null 2>&1; then
        info "  $name: 已安装, 跳过"
        return 0
    fi
    info "安装 $name (GitHub latest)..."
    local url=""
    # 通道一: api.github.com (直连失败自动走 gh-proxy.com 镜像)
    url=$(gh_curl "https://api.github.com/repos/${repo}/releases/latest" \
        --connect-timeout 10 --max-time 25 \
        | grep -o '"browser_download_url": *"[^"]*"' | cut -d '"' -f 4 \
        | grep -E "$pattern" | head -1)
    # 通道二: github.com expanded_assets (api 403/不可达时回退)
    if [[ -z "$url" ]]; then
        local tag=""
        tag=$(gh_curl "https://github.com/${repo}/releases/latest" \
            -fsSI --connect-timeout 10 --max-time 20 \
            | grep -i '^location' | sed 's|.*/tag/||' | tr -d '\r')
        if [[ -n "$tag" ]]; then
            url=$(gh_curl "https://github.com/${repo}/releases/expanded_assets/${tag}" \
                --connect-timeout 10 --max-time 25 \
                | grep -oE 'href="/[^"]*\.(rpm|deb)"' | sed 's|href="/|https://github.com/|; s|"$||' \
                | grep -E "$pattern" | head -1)
        fi
    fi
    if [[ -z "$url" ]]; then
        warn "$name 获取最新版本失败 (GitHub API 与页面均不可达, 或资产未匹配)"
        return 1
    fi
    if curl -fsSL --retry 2 --connect-timeout 20 -o "/tmp/${name}.rpm" "$url" 2>/dev/null && \
       "$DNF" install -y --skip-broken "/tmp/${name}.rpm" >/dev/null 2>&1; then
        info "  ✅ $name 安装完成 ($(basename "$url"))"
    else
        warn "$name 安装失败"
    fi
    rm -f "/tmp/${name}.rpm"
}

# ============================================================================
#  2/7  系统升级检查 (设计缺陷修复: 必须在"已升级且已重启"的系统上安装驱动,
#       否则 akmod 编译/内核模块会因内核版本不匹配失败, 音频/网卡等驱动缺失)
# ============================================================================
system_upgrade_check() {
    step "2/7 系统升级检查"
    local RUN_KERNEL
    RUN_KERNEL="$(uname -r)"

    # 1) 运行内核的模块完整性 (音频/网卡/蓝牙等位于 kernel-modules-extra,
    #    升级不完整时该包缺失会导致无声卡等硬件驱动丢失)
    if ! modinfo -F name snd-hda-intel >/dev/null 2>&1; then
        warn "运行内核 $RUN_KERNEL 缺少音频等硬件驱动模块, 修复中..."
        dnf_ensure "kernel-modules-${RUN_KERNEL}" "kernel-modules-extra-${RUN_KERNEL}" || true
        wait_rpm
        depmod -a "$RUN_KERNEL" 2>/dev/null || true
        if modinfo -F name snd-hda-intel >/dev/null 2>&1; then
            info "✅ 硬件驱动模块已补装"
        else
            warn "模块仍缺失, 请检查 dnf 仓库可用性"
        fi
    else
        info "✅ 运行内核模块完整 ($RUN_KERNEL)"
    fi

    # 2) 全量升级 (默认执行, --no-upgrade 跳过)
    if [[ "$RUN_UPGRADE" -eq 1 ]]; then
        info "执行全量系统升级 (首次运行需较长时间, 请保持网络稳定)..."
        if timeout 5400 "$DNF" upgrade --refresh -y >/dev/null 2>&1; then
            info "✅ 系统升级完成"
        else
            warn "系统升级失败/超时, 继续执行 (驱动安装可能异常)"
        fi
    else
        info "已跳过系统升级 (--no-upgrade)"
    fi

    # 3) 内核是否需要重启 (升级后必须重启, 否则驱动与运行内核不匹配)
    #    注意: 必须带 .%{ARCH}, 否则 rpm 版本(如 7.1.5-201.fc44) 与
    #    uname -r (如 7.1.5-201.fc44.x86_64) 永远不相等 → 误判需重启而退出
    local NEWEST_KERNEL
    NEWEST_KERNEL="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)"
    if [[ -n "$NEWEST_KERNEL" && "$NEWEST_KERNEL" != "$RUN_KERNEL" ]]; then
        info "检测到已安装更新内核 $NEWEST_KERNEL (当前运行 $RUN_KERNEL)"
        info "为避免驱动/音频/GPU 模块版本不匹配, 请先重启后重新运行:"
        info "  sudo reboot && sudo bash $0"
        info "(第二次运行会自动跳过升级并完成剩余安装)"
        exit 0
    fi
    info "✅ 系统内核状态正常"
}

# ============================================================================
#  1/7  软件源优化 (多站并发测速 + RPM Fusion + Flathub + 开机自启)
# ============================================================================

# 挂载 source-optimize.sh 到 KDE 开机自启 (幂等; 老版本部署过脚本但未挂载, 需补齐)
ensure_source_autostart() {
    mkdir -p "${ACTUAL_HOME}/.config/autostart" 2>/dev/null || return 1
    cat > "${ACTUAL_HOME}/.config/autostart/source-optimize.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Source Optimize
Comment=开机自动刷新软件源缓存 (仅首次)
Exec=${SCRIPTS_DIR}/source-optimize.sh
Terminal=true
X-KDE-autostart-after=panel
EOF
    chown -R "$ACTUAL_USER:" "${ACTUAL_HOME}/.config/autostart" 2>/dev/null || true
    return 0
}

optimize_sources() {
    step "1/7 软件源优化"

    # 幂等: 开机源优化脚本已部署 → 完整源优化此前已完成, 跳过重复执行 (避免冗余)
    #  (source-optimize.sh 仅在完整优化成功后部署, 其存在即代表镜像/仓库已配置好)
    if [[ -f "${SCRIPTS_DIR}/source-optimize.sh" ]]; then
        # 老版本可能只部署了脚本但未挂载开机自启, 这里补齐挂载
        ensure_source_autostart
        info "✅ 检测到开机源优化脚本已部署, 软件源此前已完成优化, 跳过重复执行"
        info "    (如需强制重跑: rm -f ${SCRIPTS_DIR}/source-optimize.sh && sudo bash $0 -source)"
        return 0
    fi

    # 检测包管理器
    info "检测包管理器..."
    local PKG_MGRS=()
    command -v dnf5    >/dev/null 2>&1 && PKG_MGRS+=("dnf5")
    command -v dnf     >/dev/null 2>&1 && PKG_MGRS+=("dnf")
    command -v flatpak >/dev/null 2>&1 && PKG_MGRS+=("flatpak")
    info "已检测: ${PKG_MGRS[*]}"

    # 检测桌面软件商店
    if rpm -q plasma-discover >/dev/null 2>&1; then
        info "桌面软件商店: KDE Discover 已安装"
    else
        info "安装 KDE Discover..."
        dnf_install_quiet plasma-discover plasma-discover-flatpak || true
    fi

    local MIRROR_DIR="/etc/yum.repos.d/mirrorlists"
    mkdir -p "$MIRROR_DIR"

    # 国内镜像池
    declare -A MIRROR_POOL=(
        ["TUNA"]="https://mirrors.tuna.tsinghua.edu.cn"
        ["USTC"]="https://mirrors.ustc.edu.cn"
        ["BFSU"]="https://mirrors.bfsu.edu.cn"
        ["SJTU"]="https://mirror.sjtu.edu.cn"
        ["NJU"]="https://mirror.nju.edu.cn"
        ["Aliyun"]="https://mirrors.aliyun.com"
        ["Huawei"]="https://repo.huaweicloud.com"
        ["Netease"]="https://mirrors.163.com"
    )

    # 1) 测速 Fedora 主仓库
    info "测速 Fedora 主仓库..."
    speedtest_mirrors "/fedora/releases/${FEDORA_VER}/Everything/${BASEARCH}/os/repodata/repomd.xml" MIRROR_POOL
    local FEDORA_RESULTS_COPY=("${SPEEDTEST_RESULTS[@]}")

    # 2) DNF 全局配置 (全新系统无自定义设置, 直接覆盖写入)
    info "优化 DNF 全局配置..."
    cat > /etc/dnf/dnf.conf << 'CONF'
[main]
max_parallel_downloads=10
fastestmirror=True
keepcache=True
install_weak_deps=False
defaultyes=True
CONF

    # 3) 写入 Fedora + Updates 仓库
    SPEEDTEST_RESULTS=("${FEDORA_RESULTS_COPY[@]}")
    local FEDORA_ML="${MIRROR_DIR}/fedora-main.txt"
    local FEDORA_UPDATES_ML="${MIRROR_DIR}/fedora-updates.txt"

    if generate_mirrorlist "$FEDORA_ML" "/fedora/releases/\$releasever/Everything/\$basearch/os/" && \
       generate_mirrorlist "$FEDORA_UPDATES_ML" "/fedora/updates/\$releasever/Everything/\$basearch/"; then
        cat > /etc/yum.repos.d/fedora.repo << REPO
[fedora]
name=Fedora \$releasever - \$basearch
mirrorlist=file://${FEDORA_ML}
enabled=1
countme=1
metadata_expire=7d
repo_gpgcheck=0
type=rpm
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
skip_if_unavailable=False
REPO
        cat > /etc/yum.repos.d/fedora-updates.repo << REPO
[updates]
name=Fedora \$releasever - \$basearch - Updates
mirrorlist=file://${FEDORA_UPDATES_ML}
enabled=1
countme=1
metadata_expire=6h
repo_gpgcheck=0
type=rpm
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
skip_if_unavailable=False
REPO
    fi

    # 4) RPM Fusion
    info "安装 RPM Fusion..."
    if ! rpm -q rpmfusion-free-release &>/dev/null; then
        "$DNF" install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
            2>/dev/null || warn "RPM Fusion 安装失败"
    fi

    info "测速 RPM Fusion 镜像..."
    speedtest_mirrors "/rpmfusion/free/fedora/releases/${FEDORA_VER}/Everything/${BASEARCH}/os/repodata/repomd.xml" MIRROR_POOL

    local RF_ML="${MIRROR_DIR}/rpmfusion.txt"
    local RF_UPDATES_ML="${MIRROR_DIR}/rpmfusion-updates.txt"
    local RF_NONFREE_ML="${MIRROR_DIR}/rpmfusion-nonfree.txt"
    local RF_NONFREE_UPDATES_ML="${MIRROR_DIR}/rpmfusion-nonfree-updates.txt"

    if generate_mirrorlist "$RF_ML" "/rpmfusion/free/fedora/releases/\$releasever/Everything/\$basearch/os/" && \
       generate_mirrorlist "$RF_UPDATES_ML" "/rpmfusion/free/fedora/updates/\$releasever/\$basearch/" && \
       generate_mirrorlist "$RF_NONFREE_ML" "/rpmfusion/nonfree/fedora/releases/\$releasever/Everything/\$basearch/os/" && \
       generate_mirrorlist "$RF_NONFREE_UPDATES_ML" "/rpmfusion/nonfree/fedora/updates/\$releasever/\$basearch/"; then
        for repo_file in /etc/yum.repos.d/rpmfusion-*.repo; do
            [[ -f "$repo_file" ]] || continue
            local ml_file=""
            case "$(basename "$repo_file")" in
                rpmfusion-free.repo)            ml_file="$RF_ML" ;;
                rpmfusion-free-updates.repo)    ml_file="$RF_UPDATES_ML" ;;
                rpmfusion-nonfree.repo)         ml_file="$RF_NONFREE_ML" ;;
                rpmfusion-nonfree-updates.repo) ml_file="$RF_NONFREE_UPDATES_ML" ;;
            esac
            sed -i 's|^metalink=|#metalink=|g; s|^baseurl=|#baseurl=|g' "$repo_file"
            sed -i "/^\[.*\]/a mirrorlist=file://${ml_file}" "$repo_file"
        done
    fi

    # 5) Flathub 镜像
    dnf_install_quiet flatpak || true
    declare -A FLATHUB_MIRRORS=(
        ["SJTU"]="https://mirror.sjtu.edu.cn/flathub"
        ["USTC"]="https://mirrors.ustc.edu.cn/flathub"
        ["NJU"]="https://mirror.nju.edu.cn/flathub"
        ["TUNA"]="https://mirrors.tuna.tsinghua.edu.cn/flathub"
    )
    info "测速 Flathub 镜像..."
    speedtest_mirrors "/flathub/flathub.flatpakrepo" FLATHUB_MIRRORS
    local best_flathub="" best_flathub_name=""
    if best_flathub="$(pick_fastest_mirror)"; then
        for entry in "${SPEEDTEST_RESULTS[@]}"; do
            IFS='|' read -r url ms name <<< "$entry"
            if [[ "$url" == "$best_flathub" ]]; then best_flathub_name="$name"; break; fi
        done
    fi

    flatpak remote-delete flathub --force 2>/dev/null || true
    if [[ -n "$best_flathub" ]]; then
        flatpak remote-add --if-not-exists flathub "${best_flathub}/flathub.flatpakrepo"
        info "Flathub: $best_flathub_name"
    else
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
        info "Flathub: 官方源"
    fi

    # 6) 重建缓存
    info "重建缓存..."
    "$DNF" clean all 2>/dev/null
    "$DNF" makecache 2>&1 | tail -2 || true

    # 7) 设置开机登录后执行源优化脚本
    info "创建开机源优化脚本..."
    cat > "${SCRIPTS_DIR}/source-optimize.sh" << 'SRCSCRIPT'
#!/bin/bash
# 开机后自动优化软件源 (仅首次运行)
MARKER="$HOME/.local/scripts/.source-optimized"
[[ -f "$MARKER" ]] && exit 0
echo "[Source Optimize] 正在刷新缓存..."
sudo dnf makecache 2>/dev/null
flatpak update -y 2>/dev/null
touch "$MARKER"
echo "[Source Optimize] 完成"
SRCSCRIPT
    chmod +x "${SCRIPTS_DIR}/source-optimize.sh"
    ensure_source_autostart
    chown -R "$ACTUAL_USER:" "$SCRIPTS_DIR"

    info "✅ 软件源优化完成 (开机自启脚本已挂载, 下次登录自动刷新缓存)"
}

# ============================================================================
#  3/7  CPU/GPU驱动 + 电源方案(默认/auto-cpufreq) + 音视频解码
# ============================================================================
optimize_gpu() {
    step "3/7 CPU/GPU驱动 + 电源方案 + 音视频解码"

    local GPU_INFO HAS_NVIDIA=0 HAS_AMD=0 HAS_INTEL=0
    GPU_INFO=$(lspci -nn 2>/dev/null | grep -iE "VGA|3D|Display" || true)
    # 用 lspci -nn 的厂商 ID 检测 (描述文字不可靠: "Corporation" 含 "ati",
    #  会把 Intel/NVIDIA 设备误判成 AMD)
    echo "$GPU_INFO" | grep -qi "\[10de:"           && HAS_NVIDIA=1
    echo "$GPU_INFO" | grep -qiE "\[1002:|\[1022:"  && HAS_AMD=1
    echo "$GPU_INFO" | grep -qi "\[8086:"           && HAS_INTEL=1
    info "检测: NVIDIA=$HAS_NVIDIA  AMD=$HAS_AMD  Intel=$HAS_INTEL"

    # 禁用系统默认电源管理服务 (幂等: 已 masked 则跳过, 避免重复 systemctl 调用)
    disable_service() {  # disable_service <服务名>
        local svc="$1"
        if systemctl is-enabled "$svc" 2>/dev/null | grep -q masked; then
            return 0
        fi
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        systemctl mask "$svc.service" 2>/dev/null || true
    }

    # ── 电源管理方案 (默认官方; 仅笔记本询问是否装 auto-cpufreq) ──
    if [[ "$POWER_MODE" == "ask" ]]; then
        if compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1; then
            echo ""
            echo -e "  ${CYAN}电源管理方案${NC} (检测到笔记本, 有电池):"
            echo "    1) 系统默认 (power-profiles-daemon + amd-pstate EPP)  [官方默认, 回车直接选]"
            echo "    2) auto-cpufreq (自动调频优化)"
            read -r -p "  请选择 [1/2]: " POWER_CHOICE
            POWER_MODE="default"
            [[ "$POWER_CHOICE" == "2" ]] && POWER_MODE="auto"
        else
            info "检测到台式机 (无电池), 使用系统默认电源管理 (官方)"
            POWER_MODE="default"
        fi
    fi

    if [[ "$POWER_MODE" == "default" ]]; then
        info "电源方案: 系统默认 (power-profiles-daemon + amd-pstate EPP)"
        systemctl unmask power-profiles-daemon 2>/dev/null || true
        systemctl enable --now power-profiles-daemon 2>/dev/null || true
        systemctl enable tuned 2>/dev/null || true
        # AMD 硬件协调电源管理 (Zen4+/9955HX)
        if [[ -d /sys/devices/system/cpu/amd_pstate ]] \
           && [[ "$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)" != "active" ]]; then
            grubby --update-kernel=ALL --args="amd_pstate=active" 2>/dev/null || true
            info "已添加内核参数 amd_pstate=active (重启后生效)"
        fi
        info "日常切换: powerprofilesctl set power-saver|balanced|performance"
    else
        info "电源方案: auto-cpufreq (禁用系统默认电源服务)"
        # power-profiles-daemon (与 auto-cpufreq 冲突)
        disable_service power-profiles-daemon
        # TLP
        disable_service tlp
        disable_service tlp-sleep
        # tuned (Fedora 自带)
        disable_service tuned

        # auto-cpufreq 仅对笔记本(有电池)有意义; 台式机收益低且可能与电源策略冲突
        if ! compgen -G "/sys/class/power_supply/BAT*" >/dev/null 2>&1; then
            info "检测到台式机 (无电池), 跳过 auto-cpufreq 安装"
        else
    info "安装 auto-cpufreq 依赖..."
    dnf_install_quiet python3-pip python3-devel python3-psutil python3-dbus \
        python3-gi gobject-introspection gobject-introspection-devel \
        gtk3-devel python3-cairo cairo-devel gcc dmidecode git || true

    # 安装 auto-cpufreq (非交互式, 不再调用会卡住的官方 yum 安装器)
    local AUTO_CPUFREQ_DIR="/opt/auto-cpufreq"
    if [[ -d "${AUTO_CPUFREQ_DIR}/.git" ]]; then
        info "auto-cpufreq 已存在, 跳过克隆"
    else
        info "克隆 auto-cpufreq 仓库..."
        rm -rf "$AUTO_CPUFREQ_DIR"
        gh_clone "AdnanHodzic/auto-cpufreq" "$AUTO_CPUFREQ_DIR" || \
            warn "auto-cpufreq 克隆失败"
    fi

    if [[ -d "$AUTO_CPUFREQ_DIR" ]]; then
        local VENV="${AUTO_CPUFREQ_DIR}/venv"
        # 幂等: venv 与命令已就绪时跳过 venv 创建/pip 安装 (避免每次重复构建)
        if [[ ! -x "$VENV/bin/auto-cpufreq" ]]; then
            info "创建虚拟环境并安装 auto-cpufreq (非交互式, 使用 TUNA PyPI 镜像)..."
            # 国内网络加速: pip 走清华镜像
            export PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
            python3 -m venv --system-site-packages "$VENV" 2>/dev/null
            "$VENV/bin/pip" install --upgrade pip wheel 2>/dev/null
            if ( cd "$AUTO_CPUFREQ_DIR" && timeout 1500 "$VENV/bin/pip" install . >/dev/null 2>&1 ); then
                info "✅ auto-cpufreq 安装完成: ${VENV}/bin/auto-cpufreq"
            else
                warn "auto-cpufreq 安装失败/超时, 请手动检查网络或 PyPI 镜像"
            fi
        else
            info "✅ auto-cpufreq 已安装 (跳过 pip 安装): ${VENV}/bin/auto-cpufreq"
        fi

        # 安装为系统服务
        #  (官方 --install 在 venv 安装下会因缺少 /usr/local/share/auto-cpufreq/scripts
        #  而崩溃且不创建服务单元, 故手动部署)
        # 幂等: 服务已 active 时跳过整个服务配置段 (二次执行秒过)
        if systemctl is-active auto-cpufreq >/dev/null 2>&1; then
            info "✅ auto-cpufreq 服务运行中 (跳过服务配置)"
        elif command -v "$VENV/bin/auto-cpufreq" >/dev/null 2>&1; then
            mkdir -p /usr/local/share/auto-cpufreq/scripts 2>/dev/null || true
            cp -r "${AUTO_CPUFREQ_DIR}/scripts/." /usr/local/share/auto-cpufreq/scripts/ 2>/dev/null || true
            cat > /etc/systemd/system/auto-cpufreq.service << EOF
[Unit]
Description=auto-cpufreq - Automatic CPU speed & power optimizer
After=multi-user.target

[Service]
Type=simple
ExecStart=${VENV}/bin/auto-cpufreq --daemon
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload 2>/dev/null || true
            systemctl enable auto-cpufreq >/dev/null 2>&1 || true
            systemctl start auto-cpufreq 2>/dev/null || true
            sleep 2
            if systemctl is-active auto-cpufreq >/dev/null 2>&1; then
                info "✅ auto-cpufreq 已安装并启用"

                # PATH 链接: 官方安装器不建 /usr/bin 链接, 用户终端才能直接敲 auto-cpufreq
                if [[ ! -e /usr/local/bin/auto-cpufreq ]]; then
                    ln -sf "$VENV/bin/auto-cpufreq" /usr/local/bin/auto-cpufreq 2>/dev/null || true
                fi

                # 回退官方方案脚本: 停用 auto-cpufreq, 恢复系统默认电源管理
                mkdir -p "${ACTUAL_HOME}/.local/scripts" 2>/dev/null || true
                if [[ -d "${ACTUAL_HOME}/.local/scripts" ]]; then
                    cat > "${ACTUAL_HOME}/.local/scripts/power-official.sh" <<'EOF'
#!/bin/bash
# 回退到系统官方电源管理 (停用 auto-cpufreq, 恢复 power-profiles-daemon + tuned)
set -e
echo "==> 停用 auto-cpufreq 服务..."
sudo systemctl stop auto-cpufreq 2>/dev/null || true
sudo systemctl disable auto-cpufreq 2>/dev/null || true
sudo systemctl mask auto-cpufreq 2>/dev/null || true
echo "==> 恢复官方电源服务 (power-profiles-daemon + tuned)..."
sudo systemctl unmask power-profiles-daemon 2>/dev/null || true
sudo systemctl enable --now power-profiles-daemon 2>/dev/null || true
sudo systemctl unmask tuned 2>/dev/null || true
sudo systemctl enable --now tuned 2>/dev/null || true
echo "==> 完成! 当前为官方电源方案 (powerprofilesctl status 查看)"
EOF
                    chmod +x "${ACTUAL_HOME}/.local/scripts/power-official.sh"
                    chown "$ACTUAL_USER" "${ACTUAL_HOME}/.local/scripts/power-official.sh" 2>/dev/null || true
                    info "✅ 回退官方方案脚本: ${ACTUAL_HOME}/.local/scripts/power-official.sh (随时可运行回退)"
                fi

                info "auto-cpufreq 状态:"
                # 注意: daemon 持锁时 `--stats` 会挂起, 直接读 stats 文件更稳
                tail -n 5 /var/run/auto-cpufreq.stats 2>/dev/null || true
                info "日常查看状态: systemctl status auto-cpufreq; 实时数据: tail -f /var/run/auto-cpufreq.stats"
            else
                warn "auto-cpufreq 服务未运行, 可手动检查: systemctl status auto-cpufreq"
            fi
        else
            warn "auto-cpufreq 命令不可用, 请手动安装"
        fi
    fi
    fi
    fi

    # ── 音视频解码 ──
    # rpmfusion 的 ffmpeg 与 Fedora 官方 ffmpeg-free* 系列 (ffmpeg-free/libavcodec-free/
    # libswscale-free 等) 文件冲突. 普通 install/swap 会因 free 系列残留而失败,
    # 必须 --allowerasing 一次替换 (dnf 自动移除冲突的 free 包) (幂等: ffmpeg 已装则跳过)
    info "安装音视频解码器..."
    if rpm -q ffmpeg >/dev/null 2>&1; then
        info "ffmpeg (rpmfusion 完整版) 已安装, 跳过"
    elif rpm -q ffmpeg-free >/dev/null 2>&1; then
        wait_rpm
        if "$DNF" install --allowerasing -y --skip-unavailable ffmpeg >/dev/null 2>&1 \
           && rpm -q ffmpeg >/dev/null 2>&1; then
            info "✅ ffmpeg-free* 已替换为 rpmfusion 完整 ffmpeg (--allowerasing)"
        else
            warn "ffmpeg 替换失败 (可稍后手动: sudo dnf install --allowerasing ffmpeg)"
        fi
    else
        dnf_install_quiet ffmpeg || warn "ffmpeg 安装失败"
    fi
    # 通用解码库 (不含 GPU 专属驱动, 避免 Intel/NVIDIA 无用包进入 AMD 机)
    dnf_install_quiet ffmpeg-libs gstreamer1-plugins-base gstreamer1-plugins-good \
        gstreamer1-plugins-bad-free gstreamer1-plugins-ugly-free \
        gstreamer1-libav gstreamer1-vaapi libva libva-utils || true

    # ── NVIDIA: 官方生产分支 (595.x) + open 内核模块 ──
    #  610.x = 新特性分支(测试版): 有显示管线回归 (color_pipeline 色斑/内屏黑屏/atomic commit 失败)
    #  595.x = 生产稳定分支; Blackwell (RTX 50) 必须用 open 内核模块 (-M=open)
    if [[ "$HAS_NVIDIA" -eq 1 ]]; then
        local NV_VER NV_TARGET NV_URL NV_RUN NV_SHA
        NV_VER=$(modinfo -F version nvidia 2>/dev/null || true)

        # ── 固定使用已验证的稳定版 ──
        #  610 新特性分支 bug 太多 (色斑/内屏黑屏/atomic commit 失败/Chrome 崩溃)
        #  595 生产分支稳定; 但后续小版本也可能引入回归 (如 595.84 DP 问题),
        #  故默认钉死实测稳定的 595.80. 换版本: FF_NV_VERSION=595.xx sudo bash $0 -gpu
        NV_TARGET="${FF_NV_VERSION:-595.80}"
        if [[ "$NV_TARGET" == 610.* ]]; then
            warn "⚠ FF_NV_VERSION=610.x 为新特性分支(测试版), 已知 bug: 色斑/内屏黑屏/atomic commit 失败!"
        fi
        NV_URL="${NV_TARGET}/NVIDIA-Linux-x86_64-${NV_TARGET}.run"
        NV_RUN="/opt/nvidia/NVIDIA-Linux-x86_64-${NV_TARGET}.run"

        if [[ -n "$NV_VER" && "$NV_VER" == "$NV_TARGET" ]]; then
            info "✅ NVIDIA 驱动已是最新生产版 $NV_VER (跳过安装)"
        else
            if [[ -n "$NV_VER" ]]; then
                warn "检测到旧驱动 $NV_VER, 先卸载 rpmfusion 包..."
                "$DNF" remove -y akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-cuda \
                    xorg-x11-drv-nvidia-cuda-libs xorg-x11-drv-nvidia-libs \
                    xorg-x11-drv-nvidia-power nvidia-settings kmod-nvidia \
                    nvidia-modprobe nvidia-persistenced libva-nvidia-driver 2>/dev/null || true
                dkms remove -m nvidia -v "$NV_VER" --all 2>/dev/null || true
            fi

            # Secure Boot 检测 (官方 DKMS 模块未签名无法加载)
            if command -v mokutil >/dev/null 2>&1 \
               && [[ "$(mokutil --sb-state 2>/dev/null)" == *"enabled"* ]]; then
                warn "⚠ 检测到 Secure Boot 已启用!"
                warn "  NVIDIA 官方驱动 DKMS 模块需签名才能加载, 建议 BIOS 关闭 Secure Boot"
                warn "  或安装后执行: sudo mokutil --import /var/lib/dkms/mok.pub"
            fi

            # 下载 + 校验
            mkdir -p /opt/nvidia
            if [[ ! -f "$NV_RUN" ]]; then
                info "下载 NVIDIA $NV_TARGET (官方生产分支, ~400MB)..."
                curl -fL --retry 3 -o "$NV_RUN" "https://download.nvidia.com/XFree86/Linux-x86_64/${NV_URL}" || \
                    warn "驱动下载失败 (可稍后手动下载)"
            fi
            if [[ -f "$NV_RUN" ]]; then
                NV_SHA=$(curl -fs --max-time 20 "https://download.nvidia.com/XFree86/Linux-x86_64/${NV_TARGET}/NVIDIA-Linux-x86_64-${NV_TARGET}.run.sha256sum" 2>/dev/null | awk '{print $1}' || true)
                if [[ -n "$NV_SHA" ]] && ! echo "$NV_SHA  $NV_RUN" | sha256sum -c - >/dev/null 2>&1; then
                    warn "⚠ 驱动校验失败, 删除后重新下载"
                    rm -f "$NV_RUN"
                else
                    info "✅ 驱动文件校验通过"
                fi
            fi

            if [[ -f "$NV_RUN" ]]; then
                info "安装 NVIDIA $NV_TARGET (open 内核模块 + DKMS, 静默模式)..."
                # 关键参数: --kernel-module-type=open (Blackwell 必需) + --dkms (内核更新自动重编译)
                if sh "$NV_RUN" --silent --dkms --kernel-module-type=open; then
                    info "✅ NVIDIA $NV_TARGET (open 模块) 安装成功"
                else
                    warn "NVIDIA 安装失败, 可手动执行: sudo sh $NV_RUN --dkms --kernel-module-type=open"
                fi
            fi
        fi

        # ── NVIDIA 配置 (幂等, 每次执行) ──
        # modeset=1: Wayland/KMS 必需 (.run 安装器不生成此文件!)
        cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia_drm modeset=1 fbdev=1
EOF
        # nouveau 黑名单 (防 nouveau 抢先绑定 GPU)
        if [[ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
            cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
        fi
        # dracut 强制加载 nvidia 模块
        echo 'force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "' > /etc/dracut.conf.d/90-gpu.conf
        # VA-API 视频硬解桥接
        dnf_install_quiet libva-nvidia-driver vdpauinfo || true
        dracut --force 2>/dev/null || true
        info "✅ NVIDIA 配置完成 (modeset=1 + nouveau 黑名单 + initramfs 重建)"
    fi

    # ── AMD ──
    if [[ "$HAS_AMD" -eq 1 ]]; then
        # 幂等: amdgpu 内核模块已加载即视为已装
        if modinfo -F name amdgpu >/dev/null 2>&1; then
            info "✅ AMD 核显驱动已就绪: amdgpu (跳过安装)"
        else
            info "安装 Mesa + Vulkan..."
            dnf_install_quiet mesa-dri-drivers mesa-vulkan-drivers mesa-vulkan-drivers.i686 \
                libva-mesa-driver vulkan-radeon || true
        fi

        if [[ -f /etc/dracut.conf.d/90-gpu.conf ]]; then
            sed -i 's/= " nvidia nvidia_modeset/= " nvidia nvidia_modeset amdgpu/' /etc/dracut.conf.d/90-gpu.conf
        else
            echo 'force_drivers+=" amdgpu "' > /etc/dracut.conf.d/90-gpu.conf
        fi
    fi

    # ── Intel 核显 ──
    if [[ "$HAS_INTEL" -eq 1 ]]; then
        if modinfo -F name i915 >/dev/null 2>&1; then
            info "✅ Intel 核显驱动已就绪: i915 (跳过安装)"
        else
            info "安装 Intel 核显驱动 (Mesa + Vulkan)..."
            dnf_install_quiet mesa-dri-drivers mesa-vulkan-drivers \
                mesa-vulkan-drivers.i686 || true
        fi
        # VA-API 硬解 (Intel QSV)
        dnf_install_quiet intel-media-driver || true
    fi

    # 清理本机用不到的 GPU 专属包 (按检测到的硬件精确清理, 避免误删)
    if [[ "$HAS_NVIDIA" -eq 0 ]]; then
        for pkg in nvidia-gpu-firmware xorg-x11-drv-nvidia-libs; do
            if rpm -q "$pkg" >/dev/null 2>&1; then
                info "清理无用包: $pkg (非本机 GPU 所需)..."
                "$DNF" remove -y "$pkg" >/dev/null 2>&1 || true
            fi
        done
    fi
    if [[ "$HAS_INTEL" -eq 0 ]]; then
        if rpm -q libva-intel-media-driver >/dev/null 2>&1; then
            info "清理无用包: libva-intel-media-driver (无 Intel 核显)..."
            "$DNF" remove -y libva-intel-media-driver >/dev/null 2>&1 || true
        fi
    fi

    # 幂等: dracut 仅当配置变更时重建 (90-gpu.conf 时间戳晚于 initramfs 才触发)
    if [[ -f /etc/dracut.conf.d/90-gpu.conf ]] \
       && [[ "/etc/dracut.conf.d/90-gpu.conf" -nt "/boot/initramfs-$(uname -r).img" ]]; then
        dracut --force 2>/dev/null || true
    fi
    info "✅ GPU + auto-cpufreq + 解码 配置完成"
}

# ============================================================================
#  4/7  终端配置 (字体 + Zsh/Starship/Zinit + Konsole/Kitty)
# ============================================================================
setup_terminal() {
    step "4/7 终端配置"

    # 依赖检查: 只安装缺失的 git/curl/wget/unzip/gnupg (容错安装)
    dnf_ensure git curl wget unzip gnupg2 || true

    # 若 fonts/ 内为 tar.gz 压缩包, 解压出字体目录 (兼容两种形式)
    if [[ -d "${RES_DIR}/fonts" ]]; then
        local _font_tgz2
        for _font_tgz2 in "${RES_DIR}"/fonts/*.tar.gz; do
            [[ -f "$_font_tgz2" ]] || continue
            tar -xzf "$_font_tgz2" -C "${RES_DIR}/fonts/" 2>/dev/null
        done
    fi

    # ── 1) 字体安装 (本地 fonts/, 支持目录或 tar.gz 压缩包) ──
    # 字体体积大 (约 190MB), 不网上下载; 已安装按 fc-list 家族名判断 (幂等)
    info "安装字体..."
    local FONT_BASE="/usr/share/fonts"
    local FONT_SRC="${RES_DIR}/fonts"
    local font_copied=0

    if [[ ! -d "$FONT_SRC" ]]; then
        warn "未找到字体目录: $FONT_SRC (请放入项目 fonts/ 目录)"
    else
        local font_dir
        for font_dir in "$FONT_SRC"/*/; do
            [[ -d "$font_dir" ]] || continue
            local dest="${FONT_BASE}/$(basename "$font_dir")"
            mkdir -p "$dest"
            # 幂等: 目标目录已有同名字体文件时跳过复制
            if ! ls "$dest"/*.ttf "$dest"/*.otf >/dev/null 2>&1; then
                cp -f "$font_dir"*.tt[fc] "$font_dir"*.otf "$dest/" 2>/dev/null
                font_copied=1
            fi
            local count
            count=$(ls "$dest"/*.ttf "$dest"/*.otf 2>/dev/null | wc -l)
            info "  $(basename "$font_dir"): $count 个字重"
        done
    fi

    find "$FONT_BASE" -type f \( -name '*.ttf' -o -name '*.otf' \) -exec chmod 644 {} \; 2>/dev/null || true
    # 幂等: 有新增字体才强制刷新缓存, 否则普通更新
    if [[ "$font_copied" -eq 1 ]]; then
        fc-cache -f >/dev/null 2>&1
    else
        fc-cache >/dev/null 2>&1
    fi
    info "字体安装完成 ($(fc-list : family 2>/dev/null | sort -u | wc -l) 个字体族)"

    # ── 2) Zsh + Starship + Zinit (内嵌确定性配置, 不再依赖交互式 Z-SHIFT) ──
    info "部署 Zsh 环境..."
    dnf_install_quiet zsh eza zoxide fd-find ripgrep bat fzf btop tealdeer wl-clipboard xclip fastfetch || true
    # 幂等: 已是 zsh 登录 shell 则跳过 chsh
    if [[ "$(getent passwd "$ACTUAL_USER" | cut -d: -f7)" != "/usr/bin/zsh" ]]; then
        chsh -s /usr/bin/zsh "$ACTUAL_USER" 2>/dev/null || true
    fi

    # starship: Fedora 仓库没有, 用官方二进制 (GitHub 直连, 超时保护)
    if [[ ! -x "${ACTUAL_HOME}/.local/bin/starship" ]]; then
        info "安装 starship 提示符..."
        mkdir -p "${ACTUAL_HOME}/.local/bin"
        timeout 300 su - "$ACTUAL_USER" -c "curl -fsSL https://starship.rs/install.sh | sh -s -- -y" >/dev/null 2>&1 || \
        timeout 240 gh_curl "https://github.com/starship/starship/releases/latest/download/starship-x86_64-unknown-linux-gnu.tar.gz" > /tmp/starship.tar.gz \
            && tar -xzf /tmp/starship.tar.gz -C "${ACTUAL_HOME}/.local/bin" starship \
            && chmod +x "${ACTUAL_HOME}/.local/bin/starship" 2>/dev/null || true
        rm -f /tmp/starship.tar.gz
        if [[ -x "${ACTUAL_HOME}/.local/bin/starship" ]]; then
            info "✅ starship $("${ACTUAL_HOME}/.local/bin/starship" --version 2>/dev/null)"
        else
            warn "starship 安装失败, 可手动: curl -fsSL https://starship.rs/install.sh | sh"
        fi
    fi

    # zinit 插件管理器 (GitHub 直连克隆; 以用户身份执行, 避免 root 归属)
    if [[ ! -f "${ACTUAL_HOME}/.local/share/zinit/zinit.git/zinit.zsh" ]]; then
        info "克隆 zinit 插件管理器..."
        if ! su - "$ACTUAL_USER" -c "mkdir -p ~/.local/share/zinit && git clone --depth=1 https://github.com/zdharma-continuum/zinit.git ~/.local/share/zinit/zinit.git" >/dev/null 2>&1; then
            info "zinit 直连失败, 走 gh-proxy.com 镜像..."
            su - "$ACTUAL_USER" -c "mkdir -p ~/.local/share/zinit && git clone --depth=1 https://gh-proxy.com/https://github.com/zdharma-continuum/zinit.git ~/.local/share/zinit/zinit.git" >/dev/null 2>&1 || \
                warn "zinit 克隆失败 (可手动: git clone https://github.com/zdharma-continuum/zinit.git ~/.local/share/zinit/zinit.git)"
        fi
    fi

    # 写入 .zshrc (中文注释, 实用向: 建议/高亮/fzf-tab/zoxide/eza)
    # 幂等: 需同时满足 "Fedora Forge 标记" + "修复版顺序签名" 才跳过重写.
    #   ⚠ 旧版 v4.0 的 .zshrc 有初始化顺序缺陷: 插件在 compinit 之前加载,
    #   且 autosuggestions/fast-syntax-highlighting 先于 fzf-tab 包装了 Tab
    #   相关 widget, 导致 fzf-tab 捕获到失效副本 → Tab 补全完全无响应.
    #   因此仅凭标记判断幂等不够, 必须校验顺序签名, 旧版配置自动备份重写.
    if grep -q "Fedora Forge - Zsh 配置" "$ACTUAL_HOME/.zshrc" 2>/dev/null \
       && grep -q "fzf-tab 最先加载" "$ACTUAL_HOME/.zshrc" 2>/dev/null; then
        info "✅ .zshrc 已配置 (跳过重写)"
    else
    # 覆盖前备份用户原有配置
    if [[ -f "$ACTUAL_HOME/.zshrc" ]]; then
        cp "$ACTUAL_HOME/.zshrc" "$ACTUAL_HOME/.zshrc.fedora-forge.backup.$(date +%s)" 2>/dev/null || true
        info "已备份原 .zshrc → ~/.zshrc.fedora-forge.backup.*"
    fi
    cat > "$ACTUAL_HOME/.zshrc" << 'ZSHRC'
# ==================================================
# Fedora Forge - Zsh 配置 (MapleMono NF CN)
# ==================================================

# ---- 用户本地二进制路径 (starship 等) ----
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
# ---- opencode CLI ----
[[ -d "$HOME/.opencode/bin" ]] && export PATH="$HOME/.opencode/bin:$PATH"

# ---- Zinit 插件管理器 ----
ZINIT_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/zinit/zinit.git"
[[ -f "$ZINIT_HOME/zinit.zsh" ]] && source "$ZINIT_HOME/zinit.zsh"

# ---- 自动补全 (必须在插件之前初始化, 否则 Tab 补全失效) ----
autoload -Uz compinit
compinit -C -d "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"

# ---- 插件 (顺序关键: fzf-tab 最先加载, 捕获未被包装的原始 widget) ----
if command -v zinit >/dev/null 2>&1; then
    zinit light Aloxaf/fzf-tab
    zinit light zsh-users/zsh-autosuggestions
    zinit light zdharma-continuum/fast-syntax-highlighting
fi

# ---- Starship 提示符 ----
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

# ---- 历史记录 ----
HISTFILE=~/.zsh_history
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_SAVE_NO_DUPS

# ---- fzf-tab: cd 时用 eza 预览 ----
zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
zstyle ':fzf-tab:*' switch-group '<' '>'

# ---- zoxide 智能目录 ----
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"

# ---- 按键绑定 ----
bindkey '^>' forward-char                    # Ctrl+> 逐个接受灰色建议
bindkey '^[[1;5D' backward-word              # Ctrl+← 左移单词
bindkey '^[[1;5C' forward-word               # Ctrl+→ 右移单词
bindkey '^W' backward-kill-word              # Ctrl+W 删除单词
bindkey '^U' backward-kill-line              # Ctrl+U 删除整行

# ---- 常用别名 ----
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --icons'
alias la='eza -a --icons'
alias l='ls'
alias cat='bat --paging=never'
alias grep='rg'
alias find='fd'
alias update='sudo dnf upgrade --refresh'
alias clean='sudo dnf autoremove'
alias sz='source ~/.zshrc'
alias ez='nano ~/.zshrc'

# ---- Yazi 文件管理器 (退出后自动切换目录) ----
if command -v yazi >/dev/null 2>&1; then
    alias y='yazi'
    function yy() {
        local tmp="$(mktemp -t yazi-cwd.XXXXXX)"
        yazi "$@" --cwd-file="$tmp"
        if read -r cwd < "$tmp" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
            builtin cd -- "$cwd"
        fi
        rm -f "$tmp"
    }
fi

# ---- 登录欢迎信息 (仅交互式终端显示, ssh/脚本调用不显示) ----
if [[ -o interactive ]]; then
    command -v fastfetch >/dev/null 2>&1 && fastfetch
fi
ZSHRC
    chown "$ACTUAL_USER:" "$ACTUAL_HOME/.zshrc" 2>/dev/null || true
    info "✅ .zshrc 已写入 (compinit→fzf-tab 正确顺序 + fastfetch/Yazi)"
    fi

    # fzf-tab 原生模块 (compcap): 缺失时 Tab 补全列表无法正常捕获/展示.
    # 依赖 gcc/make/ncurses-devel, 编译一次后所有 zsh 会话自动加载
    # 需在 .zshrc 写入并首次触发 zinit 拉取插件之后执行
    # 失败不中断脚本 (编译工具缺失/网络不稳均只告警, || true 兜底)
    local FZFTAB_DIR="${ACTUAL_HOME}/.local/share/zinit/plugins/Aloxaf---fzf-tab"
    # 首次执行: 触发一次 zinit 拉取三个插件 (幂等, 已拉取则秒过)
    if [[ ! -d "$FZFTAB_DIR" ]]; then
        info "预热 zinit 插件 (首次拉取 fzf-tab/autosuggestions/fast-syntax-highlighting)..."
        su - "$ACTUAL_USER" -c "zsh -ic 'zinit self-update >/dev/null 2>&1; zinit light Aloxaf/fzf-tab; zinit light zsh-users/zsh-autosuggestions; zinit light zdharma-continuum/fast-syntax-highlighting' >/dev/null 2>&1" || true
    fi
    if [[ -d "$FZFTAB_DIR" && ! -f "$FZFTAB_DIR/modules/Src/aloxaf/fzftab.so" ]]; then
        info "编译 fzf-tab 原生模块 (compcap)..."
        dnf_ensure gcc make ncurses-devel || true
        chown -R "$ACTUAL_USER:" "$FZFTAB_DIR" 2>/dev/null || true
        if su - "$ACTUAL_USER" -c "cd '${FZFTAB_DIR}' && zsh -fc 'source ./fzf-tab.zsh && build-fzf-tab-module'" >/dev/null 2>&1 \
           && [[ -f "$FZFTAB_DIR/modules/Src/aloxaf/fzftab.so" ]]; then
            info "✅ fzf-tab compcap 模块编译完成 (Tab 补全列表将正常显示)"
        else
            warn "fzf-tab 模块编译失败, Tab 补全可能异常 (可稍后手动: cd ~/.local/share/zinit/plugins/Aloxaf---fzf-tab && zsh -fc 'source ./fzf-tab.zsh && build-fzf-tab-module')"
        fi
    fi

    # ── Yazi 终端文件管理器 (COPR varlad/yazi, 幂等: 已装/仓库已启用则跳过) ──
    # Fedora 官方仓库无 yazi, 需启用 COPR; 启用失败/安装失败均不中断脚本
    info "安装 Yazi 终端文件管理器..."
    if command -v yazi >/dev/null 2>&1; then
        info "✅ Yazi 已安装 ($(yazi --version 2>/dev/null | head -1))"
    else
        if ! "$DNF" copr list 2>/dev/null | grep -q "varlad/yazi"; then
            info "启用 COPR 仓库 varlad/yazi..."
            timeout 120 "$DNF" copr enable -y varlad/yazi >/dev/null 2>&1 || \
                warn "Yazi COPR 启用失败"
        fi
        dnf_install_quiet yazi || warn "Yazi 安装失败"
    fi
    # 图片/视频预览依赖 (仓库无此包时 dnf_ensure 自动跳过, 不中断)
    dnf_ensure ueberzugpp || true
    # 初始化 Yazi 配置目录 (首次启动由 yazi 自行生成默认配置)
    mkdir -p "$ACTUAL_HOME/.config/yazi"
    chown -R "$ACTUAL_USER:" "$ACTUAL_HOME/.config/yazi" 2>/dev/null || true

    # starship 配置 (优先使用项目 konsole/starship.toml, 缺失时退回内嵌兜底)
    # 幂等: 已存在则跳过 (内容变更需手动更新)
    mkdir -p "$ACTUAL_HOME/.config"
    if [[ -f "$ACTUAL_HOME/.config/starship.toml" ]]; then
        info "✅ starship.toml 已配置 (跳过)"
    else
    local STARSHIP_SRC="${RES_DIR}/konsole/starship.toml"
    if [[ -f "$STARSHIP_SRC" ]]; then
        cp -f "$STARSHIP_SRC" "$ACTUAL_HOME/.config/starship.toml"
        info "✅ starship.toml 已写入 (来自项目 starship.toml)"
    else
        warn "未找到 ${STARSHIP_SRC}, 使用内嵌兜底配置"
        cat > "$ACTUAL_HOME/.config/starship.toml" << 'STARSHIP'
# Fedora Forge - Starship 实用配置 (兜底)
format = "$directory$git_branch$git_status$python$nodejs$rust$cmd_duration$character"

[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"

[directory]
truncation_length = 3
truncation_symbol = "…/"
style = "bold cyan"

[git_branch]
symbol = ""
style = "bold purple"

[git_status]
style = "bold yellow"

[python]
format = "[$symbol($version)]($style) "

[nodejs]
format = "[$symbol($version)]($style) "

[rust]
format = "[$symbol($version)]($style) "

[cmd_duration]
min_time = 2000
format = "[$duration]($style) "

[username]
show_always = false
[os]
disabled = true
[time]
disabled = true
STARSHIP
    fi
    chown "$ACTUAL_USER:" "$ACTUAL_HOME/.config/starship.toml" 2>/dev/null || true
    fi

    # ── Fastfetch 配置 (优先使用项目 fastfetch/ 目录部署) ──
    # ⚠ 必踩的坑:
    #  1) fastfetch ≥2.16 只自动加载 config.jsonc, config.json 会被静默忽略
    #  2) 图片 logo 必须显式 "type" 且 source 指向真实存在的文件,
    #     扩展名必须匹配 (4.jpg 写成 4.png 会静默回退内置 ASCII logo)
    #  3) 渲染后端: kitty 终端用 "type": "kitty" (原生像素级, 零依赖,
    #     无需 chafa/timg); Konsole 等无图形协议终端需 chafa
    local FF_DIR="$ACTUAL_HOME/.config/fastfetch"
    local FF_SRC="${RES_DIR}/fastfetch"
    if [[ -d "$FF_SRC" && -f "$FF_SRC/config.jsonc" ]]; then
        mkdir -p "$FF_DIR"
        cp -f "$FF_SRC/config.jsonc" "$FF_DIR/config.jsonc"
        if [[ -d "$FF_SRC/png" ]]; then
            rm -rf "$FF_DIR/png"
            cp -rf "$FF_SRC/png" "$FF_DIR/png"
        fi
        chown -R "$ACTUAL_USER:" "$FF_DIR" 2>/dev/null || true
        info "✅ fastfetch 配置已从项目 fastfetch/ 部署 (config.jsonc + png)"
    elif [[ -f "$FF_DIR/config.json" && ! -f "$FF_DIR/config.jsonc" ]]; then
        # 旧命名兼容: config.json → config.jsonc (否则新版 fastfetch 不加载)
        mv -f "$FF_DIR/config.json" "$FF_DIR/config.jsonc" 2>/dev/null || true
        info "✅ fastfetch config.json 已重命名为 config.jsonc (否则不生效)"
    else
        info "fastfetch: 使用默认配置"
    fi

    # ── 3) Konsole: 从项目 konsole/ 部署用户完善的方案 ──
    # 包含 Shell.profile (自动复制选中/中键粘贴/字体等) + Catppuccin-Frappe 配色
    # 幂等: 用户目录已有则跳过 (尊重用户手动微调)
    info "配置 Konsole..."
    local KONSOLE_DIR="$ACTUAL_HOME/.local/share/konsole"
    local KONSOLE_SRC="${RES_DIR}/konsole"
    if [[ -f "$KONSOLE_DIR/Shell.profile" ]] && [[ -f "$KONSOLE_DIR/Catppuccin-Frappe.colorscheme" ]]; then
        info "✅ Konsole 方案已配置 (跳过)"
    elif [[ -d "$KONSOLE_SRC" ]]; then
        mkdir -p "$KONSOLE_DIR"
        cp -f "$KONSOLE_SRC/Shell.profile" "$KONSOLE_SRC/Catppuccin-Frappe.colorscheme" "$KONSOLE_DIR/"
        info "✅ Konsole 方案已从项目 konsole/ 部署 (Shell.profile + 配色)"
    else
        warn "未找到项目 konsole/ 目录, 使用内嵌基础配置"
        cat > "$KONSOLE_DIR/Catppuccin-Frappe.colorscheme" << 'KONSCHEME'
[Background]
Color=48,52,70

[Color0]
Color=115,121,148

[Color1]
Color=231,130,132

[Color2]
Color=166,209,137

[Color3]
Color=229,200,144

[Color4]
Color=140,170,238

[Color5]
Color=202,158,230

[Color6]
Color=153,209,219

[Color7]
Color=198,208,245

[Foreground]
Color=198,208,245

[General]
Description=Catppuccin Frappé
KONSCHEME
        cat > "$KONSOLE_DIR/Shell.profile" << 'KONPROF'
[General]
Name=Shell
Parent=FALLBACK/
ColorScheme=Catppuccin Frappe
Font=Maple Mono NF CN,13

[Scrolling]
HistoryMode=2
HistorySize=10000

[Terminal Features]
BlinkingCursorEnabled=false
KONPROF
    fi
    if command -v kwriteconfig6 >/dev/null 2>&1; then
        su - "$ACTUAL_USER" -c "kwriteconfig6 --file konsolerc --group 'Desktop Entry' --key DefaultProfile Shell.profile" 2>/dev/null || true
    fi
    chown -R "$ACTUAL_USER:" "$KONSOLE_DIR" 2>/dev/null || true
    info "✅ Konsole: Catppuccin Frappe + MapleMono 13pt, 已设为默认"

    # ── 4) Kitty (Sidharth7082/kitty 方案: 170+ 主题 + 透明/模糊 + 主题切换器) ──
    # 优先级: 已配置跳过 → GitHub 在线克隆 → 本地 kitty/ 兜底 → 内嵌基础配置
    info "安装 Kitty + rofi (主题切换器依赖)..."
    dnf_install_quiet kitty rofi || true

    local KITTY_CFG_DIR="${ACTUAL_HOME}/.config/kitty"
    local KITTY_SRC="${RES_DIR}/kitty"

    deploy_kitty_dir() {  # deploy_kitty_dir <方案根目录> <主题目录>
        local src_root="$1" src_themes="$2"
        mkdir -p "$KITTY_CFG_DIR"
        cp -f "$src_root/kitty.conf" "$src_root/kitty-theme.sh" "$KITTY_CFG_DIR/" 2>/dev/null
        mkdir -p "$KITTY_CFG_DIR/kitty-themes"
        rm -rf "$KITTY_CFG_DIR/kitty-themes/themes"
        [[ -n "$src_themes" && -d "$src_themes" ]] && cp -r "$src_themes" "$KITTY_CFG_DIR/kitty-themes/themes" 2>/dev/null
        chmod +x "$KITTY_CFG_DIR/kitty-theme.sh" 2>/dev/null
    }

    if [[ -f "$KITTY_CFG_DIR/kitty-theme.sh" ]] && [[ -d "$KITTY_CFG_DIR/kitty-themes/themes" ]]; then
        info "✅ Kitty 方案已配置 (跳过)"
    else
        local KITTY_OK=0
        # 在线: GitHub 克隆 (直连失败走 gh-proxy.com 镜像)
        if { su - "$ACTUAL_USER" -c "git clone --depth=1 https://github.com/Sidharth7082/kitty.git /tmp/kitty-style" >/dev/null 2>&1 \
             || su - "$ACTUAL_USER" -c "git clone --depth=1 https://gh-proxy.com/https://github.com/Sidharth7082/kitty.git /tmp/kitty-style" >/dev/null 2>&1; } \
           && [[ -f /tmp/kitty-style/kitty/kitty.conf ]]; then
            deploy_kitty_dir "/tmp/kitty-style/kitty" "/tmp/kitty-style/kitty/themes"
            rm -rf /tmp/kitty-style
            KITTY_OK=1
            info "✅ Kitty 方案已从 GitHub 克隆部署"
        fi
        # 离线兜底: 本地项目目录
        if [[ "$KITTY_OK" -eq 0 && -d "$KITTY_SRC" && -f "$KITTY_SRC/kitty.conf" ]]; then
            local KITTY_THEMES_SRC=""
            [[ -d "$KITTY_SRC/themes" ]] && KITTY_THEMES_SRC="$KITTY_SRC/themes"
            [[ -z "$KITTY_THEMES_SRC" && -d "$KITTY_SRC/kitty-themes/themes" ]] && KITTY_THEMES_SRC="$KITTY_SRC/kitty-themes/themes"
            deploy_kitty_dir "$KITTY_SRC" "$KITTY_THEMES_SRC"
            KITTY_OK=1
            info "✅ Kitty 方案已从本地 kitty/ 部署 (GitHub 不可用)"
        fi
        # 最终兜底: 内嵌基础配置
        if [[ "$KITTY_OK" -eq 0 ]]; then
            warn "Kitty 方案获取失败 (网络/本地均不可用), 退回内嵌基础配置"
            mkdir -p "$KITTY_CFG_DIR"
            cat > "$KITTY_CFG_DIR/kitty.conf" << 'KITTYFALLBACK'
# Fedora Forge - Kitty 基础配置 (在线方案不可用时的兜底)
font_family Maple Mono NF CN
font_size 13
background_opacity 0.92
enable_audio_bell no
scrollback_lines 10000
KITTYFALLBACK
        fi
    fi

    # 适配: 字体换为脚本已装的 MapleMono; 背景图路径适配目标用户家目录
    # (kitty.conf 中写的是固定路径, 换机器运行时按 ACTUAL_HOME 重写;
    #  背景图文件由用户手动放入 ~/图片/wallpapers/, 脚本不复制)
    sed -i 's/^font_family.*/font_family Maple Mono NF CN/; s/^font_size.*/font_size 13.0/' \
        "$KITTY_CFG_DIR/kitty.conf" 2>/dev/null
    sed -i "s|^background_image .*|background_image ${ACTUAL_HOME}/图片/wallpapers/fdg3-wer4.png|" \
        "$KITTY_CFG_DIR/kitty.conf" 2>/dev/null
    chown -R "$ACTUAL_USER:" "$KITTY_CFG_DIR" 2>/dev/null || true
    if timeout 10 kitty --config "$KITTY_CFG_DIR/kitty.conf" --version >/dev/null 2>&1; then
        info "✅ Kitty 方案生效 (kitty 配置解析通过, 运行 kitty-theme.sh 可切换 170+ 主题)"
    else
        warn "kitty.conf 解析失败, 请检查 $KITTY_CFG_DIR/kitty.conf"
    fi

    # ── Kitty 主题切换器: 使用提示 (不绑定全局快捷键, KDE 组件注册不可靠) ──
    # 手动切换: 运行 ~/.config/kitty/kitty-theme.sh 弹出 rofi 选择器
    if [[ -f "$KITTY_CFG_DIR/kitty-theme.sh" ]]; then
        info "✅ Kitty 主题切换器就绪: 运行 ${CYAN}~/.config/kitty/kitty-theme.sh${NC} 弹出 rofi 选择主题"
    fi

    chown -R "$ACTUAL_USER:" "$ACTUAL_HOME/.local/share/konsole" "$ACTUAL_HOME/.config" 2>/dev/null || true

    # ⚠ 归属修正: 脚本以 root 运行时, starship/zinit 等落盘文件归 root,
    #   用户 zsh 将无法创建 zinit 插件目录 (实测: 插件加载全线失败).
    #   统一递归修正用户本地目录归属
    chown -R "$ACTUAL_USER:" "$ACTUAL_HOME/.local/bin" "$ACTUAL_HOME/.local/share/zinit" 2>/dev/null || true

    # ── Tab 补全自检: 验证 fzf-tab 绑定与 compinit 就绪 (失败不静默) ──
    info "自检 Tab 补全..."
    if su - "$ACTUAL_USER" -c "zsh -ic 'bindkey | command grep -q complete'" >/dev/null 2>&1; then
        info "✅ zsh 补全绑定正常 (Tab → fzf-tab)"
    else
        warn "WARNING: zsh completion initialization failed"
        warn "请重启终端 (或执行: exec zsh) 后重试; 仍失败请检查 ~/.local/share/zinit 权限与网络"
    fi

    # ── 终端组件最终验证清单 ──
    echo ""
    info "Terminal setup check:"
    local _tcmd
    for _tcmd in zsh starship fastfetch fzf yazi; do
        if command -v "$_tcmd" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} $_tcmd installed"
        else
            echo -e "  ${YELLOW}✗${NC} $_tcmd not found"
        fi
    done
    unset _tcmd
    if command -v zinit >/dev/null 2>&1 || [[ -f "${ACTUAL_HOME}/.local/share/zinit/zinit.git/zinit.zsh" ]]; then
        echo -e "  ${GREEN}✓${NC} zinit installed"
    else
        echo -e "  ${YELLOW}✗${NC} zinit not installed"
    fi
    if [[ -d "${ACTUAL_HOME}/.local/share/zinit/plugins/Aloxaf---fzf-tab" ]]; then
        echo -e "  ${GREEN}✓${NC} fzf-tab installed"
    else
        echo -e "  ${YELLOW}✗${NC} fzf-tab not installed"
    fi
    if su - "$ACTUAL_USER" -c "zsh -ic 'bindkey | command grep -q complete'" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} zsh completion enabled"
    else
        echo -e "  ${YELLOW}✗${NC} zsh completion disabled"
    fi
    echo ""
    echo -e "  重启终端: ${CYAN}exec zsh${NC} (新终端 Tab 即可使用 fzf 补全, 显示 fastfetch)"
    info "✅ 终端配置完成"
}

# ============================================================================
#  5/7  主题 & 系统优化 (含 NetworkManager 优化)
# ============================================================================
# ─────────────────────────────────────────────────────────────
# 清理系统自带壁纸 (Fedora/KDE 预装, 仅保留用户自定义壁纸)
cleanup_stock_wallpapers() {
    info "清理系统自带壁纸..."
    local -a STOCK=(
        Altai Autumn BytheWater Canopee Cascade Cluster Coast ColdRipple
        ColorfulCups DarkestHour Elarun EveningGlow FallenLeaf Fedora F44
        Flow Grey Honeywave IceCold Kay Kite Kokkini MilkyWay Mountain
        Nexus Nuvole OneStandsOut Opal Orionids PastelHills Patak Path
        SafeLanding ScarletTree Shell Sub-Arctic Volna summer_1am FlyingKonqui
    )
    local removed=0
    for w in "${STOCK[@]}"; do
        if [[ -d "/usr/share/wallpapers/$w" ]]; then
            rm -rf "/usr/share/wallpapers/$w"
            ((removed++))
        fi
    done
    if [[ $removed -gt 0 ]]; then
        info "✅ 已删除 $removed 个系统自带壁纸"
    else
        info "系统壁纸已清理过 (0 个待删)"
    fi
}

apply_theme() {
    step "5/7 主题 & 系统优化"

    # ── 0) 清理系统自带壁纸 (仅保留用户自定义壁纸) ──
    cleanup_stock_wallpapers

    # ── 1) KDE Breeze 微风主题 ──
    info "切换回 KDE Breeze 微风主题..."
    if command -v lookandfeeltool >/dev/null 2>&1; then
        su - "$ACTUAL_USER" -c "lookandfeeltool --apply org.kde.breezedark.desktop 2>/dev/null || lookandfeeltool --apply org.kde.breeze.desktop 2>/dev/null" || true
    fi

    # 安全清理: 只删明确的第三方主题, 严禁触碰 default/Breeze
    #  (老版本用 find -name '*theme*' 把 desktoptheme 父目录整个删掉,
    #   导致 Plasma 黑屏 — 已废弃该做法)
    local USER_PLASMA_DIR="${ACTUAL_HOME}/.local/share/plasma"

    # 先确保 Plasma 必需的桌面主题存在, 被误删时从系统恢复
    mkdir -p "${USER_PLASMA_DIR}/desktoptheme"
    if [[ ! -d "${USER_PLASMA_DIR}/desktoptheme/default" && -d /usr/share/plasma/desktoptheme/default ]]; then
        cp -a /usr/share/plasma/desktoptheme/default "${USER_PLASMA_DIR}/desktoptheme/default"
        info "已恢复 Plasma 必需主题: desktoptheme/default"
    fi

    # 清理函数: 白名单保留 default 与 *breeze*, 其余第三方主题删除
    clean_theme_dirs() {   # $1=要清理的完整目录
        local sub="$1" dir name
        [[ -d "$sub" ]] || return 0
        local found=0
        for dir in "$sub"/*; do
            [[ -d "$dir" ]] || continue
            name="$(basename "$dir")"
            [[ "$name" == "default" || "$name" == Default* || "$name" == *breeze* ]] && continue
            rm -rf "$dir"
            info "  已清理第三方主题: $name"
            found=1
        done
        [[ "$found" -eq 1 ]] || info "  未发现可清理的第三方主题 ($(basename "$sub"))"
    }
    clean_theme_dirs "${USER_PLASMA_DIR}/desktoptheme"
    clean_theme_dirs "${USER_PLASMA_DIR}/look-and-feel"
    clean_theme_dirs "${ACTUAL_HOME}/.local/share/aurorae/themes"

    # 颜色方案: 只保留 Breeze 系
    if [[ -d "${ACTUAL_HOME}/.local/share/color-schemes" ]]; then
        find "${ACTUAL_HOME}/.local/share/color-schemes" -maxdepth 1 -type f -name "*.colors" ! -name "*Breeze*" -delete 2>/dev/null || true
    fi

    # 系统级 look-and-feel 清理 (白名单仅保留 breeze/default)
    #  Fedora 官方主题 org.fedoraproject.* 不好看, 一并清理 (纯文件删除)
    if [[ -d /usr/share/plasma/look-and-feel ]]; then
        local sys_laf laf_name
        for sys_laf in /usr/share/plasma/look-and-feel/*/; do
            [[ -d "$sys_laf" ]] || continue
            laf_name="$(basename "$sys_laf")"
            [[ "$laf_name" == *breeze* || "$laf_name" == *default* ]] && continue
            rm -rf "$sys_laf"
            info "  已清理系统 look-and-feel 主题: $laf_name"
        done
    fi

    # Fedora 官方主题为 rpm 包安装, 直接卸载会触发强依赖, 只能删文件;
    #  用 mark install + versionlock 防止 autoremove / 更新把文件装回
    #  (幂等: versionlock 已含该包则跳过 dnf 调用)
    if ! "$DNF" versionlock list 2>/dev/null | grep -q plasma-lookandfeel-fedora; then
        wait_rpm
        "$DNF" mark install plasma-lookandfeel-fedora 2>/dev/null || true
        "$DNF" versionlock add plasma-lookandfeel-fedora 2>/dev/null || \
            warn "versionlock 不可用, 请手动: dnf versionlock add plasma-lookandfeel-fedora"
        info "已锁定官方主题包: plasma-lookandfeel-fedora"
    else
        info "官方主题包已锁定 (跳过)"
    fi

    # 重新应用一次 Breeze 并清缓存, 让桌面立刻生效 (修复可能残留的黑屏)
    #  (headless/SSH 下 lookandfeeltool 可能 core dump; 幂等: kcfg 已设置则跳过)
    if ! grep -q '^LookAndFeelPackage=org.kde.breezedark.desktop' \
            "${ACTUAL_HOME}/.config/plasma-lookandfeel.kcfg" 2>/dev/null; then
        su - "$ACTUAL_USER" -c "lookandfeeltool --apply org.kde.breezedark.desktop 2>/dev/null || lookandfeeltool --apply org.kde.breeze.desktop 2>/dev/null
            rm -rf ~/.cache/plasma_theme_* ~/.cache/plasma 2>/dev/null" || true
    fi

    # 清理系统 LAF 后确保全局主题引用有效 (防止引用被删的 fedora 主题导致黑屏)
    if command -v kwriteconfig6 >/dev/null 2>&1; then
        su - "$ACTUAL_USER" -c "kwriteconfig6 --file plasma-lookandfeel.kcfg --group KDE --key LookAndFeelPackage org.kde.breezedark.desktop" 2>/dev/null || true
    fi

    # ── 2) Plasma Login Manager 登录背景 (幂等: 已设置且文件一致则跳过) ──
    info "配置登录背景图..."
    local LOGIN_BG="${RES_DIR}/wallpapers/wallhaven-9mqvz1.png"
    if [[ -f "$LOGIN_BG" ]] \
       && grep -q "Image=file:///usr/share/backgrounds/plasmalogin/login.png" /etc/plasmalogin.conf 2>/dev/null \
       && cmp -s "$LOGIN_BG" /usr/share/backgrounds/plasmalogin/login.png 2>/dev/null; then
        info "登录背景图已设置 (跳过)"
    elif [[ -f "$LOGIN_BG" ]]; then
        mkdir -p /usr/share/backgrounds/plasmalogin
        cp "$LOGIN_BG" /usr/share/backgrounds/plasmalogin/login.png
        chmod 644 /usr/share/backgrounds/plasmalogin/login.png

        cat > /etc/plasmalogin.conf << 'LOGIN'
[Greeter][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/plasmalogin/login.png
LOGIN
        info "登录背景图已设置"
    else
        warn "未找到 wallhaven-9mqvz1.png (请放入项目 wallpapers/)"
    fi

    # ── 3) SELinux → Permissive (幂等: 已为 permissive 则跳过) ──
    if [[ -f /etc/selinux/config ]] && ! grep -q '^SELINUX=permissive' /etc/selinux/config; then
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
        info "SELinux: permissive (重启后生效)"
    else
        info "SELinux: 已是 permissive"
    fi

    # ── 4) 固件更新 (幂等: 元数据 7 天内刷新过则跳过, 避免每次联网下载) ──
    if command -v fwupdmgr >/dev/null 2>&1; then
        local FW_CACHE="/var/cache/fwupd/metadata.db"
        if [[ -f "$FW_CACHE" ]] && [[ -z "$(find "$FW_CACHE" -mmin +10080 2>/dev/null)" ]]; then
            info "固件元数据 7 天内已刷新 (跳过)"
        else
            info "检查固件更新..."
            fwupdmgr refresh --force 2>/dev/null || true
            fwupdmgr get-updates 2>/dev/null || true
            info "固件检查完成 (有更新请运行: fwupdmgr update)"
        fi
    fi

    # ══════════════════════════════════════════════
    #  5) NetworkManager 优化
    #  - 禁用 wait-online (加速开机)
    #  - 禁用连通性检测 (减少网络请求)
    # ══════════════════════════════════════════════
    info "NetworkManager 优化..."
    # 幂等: wait-online 已 masked 则跳过
    if [[ "$(systemctl is-enabled NetworkManager-wait-online.service 2>/dev/null)" == "masked" ]]; then
        info "  - wait-online: 已禁用 (跳过)"
    else
        systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
        systemctl mask NetworkManager-wait-online.service 2>/dev/null || true
        info "  - wait-online 服务: 已禁用并 mask"
    fi

    # 连通性检测: 在 /etc/NetworkManager/NetworkManager.conf 追加 [connectivity] 段
    #   (幂等: 键已存在则跳过; 仅首次写入时重启 NetworkManager)
    local NM_CONF="/etc/NetworkManager/NetworkManager.conf"
    if grep -q '^enabled=false' "$NM_CONF" 2>/dev/null; then
        info "  - 连通性检测: 已禁用 (跳过)"
    else
        printf '\n[connectivity]\nenabled=false\n' >> "$NM_CONF"
        info "  - 连通性检测: 已禁用 (NetworkManager.conf 追加 [connectivity])"
        systemctl restart NetworkManager 2>/dev/null || true
        info "  - NetworkManager 已重启"
    fi

    # ── 6) GRUB (CyberGRUB-2077) ──
    if [[ -f /etc/default/grub ]] && command -v grub2-mkconfig >/dev/null 2>&1; then
        sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=30/' /etc/default/grub

        local THEME_DIR="/boot/grub2/themes" THEME_SRC="" THEME_TXT=""
        mkdir -p "$THEME_DIR"
        # 优先: 已安装则跳过 (幂等)
        if [[ -d "$THEME_DIR/CyberGRUB-2077" ]]; then
            THEME_TXT=$(find "$THEME_DIR" -name "theme.txt" 2>/dev/null | head -1)
            info "CyberGRUB-2077: 已安装 (跳过)"
        else
            # 在线: GitHub 克隆 (网络优先)
            info "下载 CyberGRUB-2077 (GitHub)..."
            if gh_clone "adnksharp/CyberGRUB-2077" /tmp/cybergrub; then
                # 仓库结构: 主题文件在子目录 CyberGRUB-2077/
                local theme_src_dir=""
                if [[ -d /tmp/cybergrub/CyberGRUB-2077 ]]; then
                    theme_src_dir="/tmp/cybergrub/CyberGRUB-2077"
                elif [[ -f /tmp/cybergrub/theme.txt ]]; then
                    theme_src_dir="/tmp/cybergrub"
                fi
                if [[ -n "$theme_src_dir" ]]; then
                    cp -r "$theme_src_dir" "$THEME_DIR/CyberGRUB-2077" 2>/dev/null || true
                fi
            fi
            rm -rf /tmp/cybergrub 2>/dev/null
            THEME_TXT=$(find "$THEME_DIR" -name "theme.txt" 2>/dev/null | head -1)
            if [[ -z "$THEME_TXT" ]]; then
                # 离线兜底: 项目目录
                warn "GitHub 下载失败, 尝试本地 CyberGRUB-2077/ 兜底..."
                local theme_root="${SCRIPT_DIR}/CyberGRUB-2077"
                if [[ -d "$theme_root" ]]; then
                    if [[ -d "$theme_root/CyberGRUB-2077" ]]; then
                        cp -r "$theme_root/CyberGRUB-2077" "$THEME_DIR/" 2>/dev/null || true
                    else
                        cp -r "$theme_root" "$THEME_DIR/CyberGRUB-2077" 2>/dev/null || true
                    fi
                fi
                THEME_TXT=$(find "$THEME_DIR" -name "theme.txt" 2>/dev/null | head -1)
            fi
            if [[ -n "$THEME_TXT" ]]; then
                info "✅ CyberGRUB-2077 安装完成"
            else
                warn "CyberGRUB-2077 安装失败 (网络与本地均不可用)"
            fi
        fi
        # 主题文件已就绪则写入 GRUB 配置
        if [[ -n "$THEME_TXT" ]]; then
            sed -i '/^GRUB_THEME=/d' /etc/default/grub
            echo "GRUB_THEME=\"${THEME_TXT}\"" >> /etc/default/grub
            # ⚠ 关键: 必须显式 GRUB_TERMINAL_OUTPUT="gfxterm", 否则 00_header 中
            #   gfxterm 判定为 0, 整个主题块被跳过 → 主题永不生效 (实测缺陷)
            sed -i '/^GRUB_TERMINAL_OUTPUT=/d' /etc/default/grub
            echo 'GRUB_TERMINAL_OUTPUT="gfxterm"' >> /etc/default/grub
        fi

        # 幂等: grub.cfg 已含主题 + GRUB_THEME 已设置且无改动时跳过重生成 (省 10-30s)
        if grep -q "set theme=.*theme.txt" /boot/grub2/grub.cfg 2>/dev/null \
           && grep -q "^GRUB_THEME=" /etc/default/grub 2>/dev/null; then
            info "GRUB: 主题已生效 (跳过重生成, 超时=30s)"
        else
            grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true
            if grep -q "set theme=.*theme.txt" /boot/grub2/grub.cfg 2>/dev/null; then
                info "GRUB: 超时=30s (显示菜单) + CyberGRUB-2077 (重启后生效)"
            else
                warn "GRUB 主题行未写入 grub.cfg (重启后主题不生效, 请检查 /etc/default/grub)"
            fi
        fi

        # BLS 启动项标题: 系统名 + 内核短版本号 (如 Fedora Linux-7.1.5)
        if [[ -d /boot/loader/entries ]]; then
            for f in /boot/loader/entries/*.conf; do
                [[ -f "$f" ]] || continue
                local short=""
                case "$(basename "$f" 2>/dev/null)" in
                    *-0-rescue.conf)
                        sed -i 's/^title .*/title Fedora Linux (Rescue)/' "$f" 2>/dev/null || true ;;
                    *.conf)
                        short=$(sed -n 's/^version[[:space:]]*//p' "$f" 2>/dev/null | head -1 | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')
                        if [[ -n "$short" ]]; then
                            sed -i "s/^title .*/title Fedora Linux-${short}/" "$f" 2>/dev/null || true
                        else
                            sed -i 's/^title .*/title Fedora Linux/' "$f" 2>/dev/null || true
                        fi ;;
                esac
            done
            # 内核升级会重建 .conf 并恢复长标题, 安装 drop-in 保持精简
            if mkdir -p /etc/kernel/install.d 2>/dev/null; then
                cat > /etc/kernel/install.d/91-short-title.install <<'EOD'
#!/bin/sh
# 内核安装/更新后, 保持 BLS 启动项标题为 系统名-内核短版本号 (由 fedora-forge 安装)
[ "$COMMAND" = "add" ] || exit 0
for f in /boot/loader/entries/*.conf; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        *-0-rescue.conf)
            sed -i 's/^title .*/title Fedora Linux (Rescue)/' "$f" ;;
        *)
            short=$(sed -n 's/^version[[:space:]]*//p' "$f" | head -1 | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')
            if [ -n "$short" ]; then
                sed -i "s/^title .*/title Fedora Linux-${short}/" "$f"
            else
                sed -i 's/^title .*/title Fedora Linux/' "$f"
            fi ;;
    esac
done
exit 0
EOD
                chmod +x /etc/kernel/install.d/91-short-title.install 2>/dev/null || true
            fi
            info "启动项标题: 系统名+内核版本号 (如 Fedora Linux-7.1.5, 内核升级后自动保持)"
        fi
    fi

    # fstrim 定时清理
    systemctl enable fstrim.timer 2>/dev/null || true

    info "✅ 主题 & 系统优化完成"
}

# ============================================================================
#  6/7  应用管理 (卸载 + 安装)
# ============================================================================
manage_apps() {
    step "6/7 应用管理"

    # ═══════════ 卸载: 扫描指定清单 ═══════════
    info "扫描待卸载应用..."
    local REMOVABLE=(
        pim-sieve-editor grantlee-editor kaddressbook kontact korganizer kmail
        libreoffice-core okular khelpcenter plasma-welcome kinfocenter filelight
        kmouth kfind akonadi-import-wizard kleopatra kwrite pim-data-exporter
        akregator firefox kde-connect krdc krfb neochat skanpage im-chooser
        mediawriter kjournald kde-partitionmanager dragon elisa-player kamoso
        qrca kmines kpat kmahjongg ibus
    )
    local FOUND=() pkg
    for pkg in "${REMOVABLE[@]}"; do
        rpm -q "$pkg" >/dev/null 2>&1 && FOUND+=("$pkg")
    done

    if [[ ${#FOUND[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}检测到 ${#FOUND[@]} 个可卸载应用:${NC}"
        echo "  ────────────────────────────────────"
        printf "  %s\n" "${FOUND[@]}" | sed 's/^/  • /'
        echo "  ────────────────────────────────────"
        echo -e "${YELLOW}是否卸载以上应用? [Y/n] (60 秒无输入默认卸载):${NC}"
        local answer=""
        read -r -t 60 answer || answer="y"
        case "$answer" in
            ""|y|Y|yes|YES)
                wait_rpm
                info "正在卸载: ${FOUND[*]}"
                "$DNF" remove -y "${FOUND[@]}" 2>/dev/null || warn "部分应用卸载失败 (可稍后手动 dnf remove)"
                info "✅ 卸载完成"
                ;;
            *)
                info "已跳过卸载"
                ;;
        esac
    else
        info "清单中的应用均未安装, 跳过卸载"
    fi

    # ═══════════ dnf 安装 ═══════════
    # ── Fcitx5 + Rime 雾凇 ──
    info "安装 Fcitx5 + Rime 雾凇..."
    rpm -q ibus >/dev/null 2>&1 && "$DNF" remove -y ibus ibus-* 2>/dev/null || true
    dnf_ensure fcitx5 fcitx5-gtk fcitx5-qt fcitx5-rime librime-lua librime-octagram fcitx5-configtool

    # fcitx5 环境变量 (KDE/X11 必需, 否则输入法无法拦截应用输入)
    if ! grep -q "XMODIFIERS" /etc/profile.d/fcitx5-env.sh 2>/dev/null; then
        cat > /etc/profile.d/fcitx5-env.sh <<'FC'
export XMODIFIERS=@im=fcitx
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
FC
    fi

    # 雾凇方案 (rime-ice): fcitx5 首次启动会预占 rime 目录并生成默认运行时文件,
    # 无 default.yaml/方案时为仿冒目录, 需要备份后克隆 (二次执行也能重建)
    # ⚠ 特征文件必须用 rime-ice 实际存在的 rime_ice.schema.yaml:
    #   曾误用 luna_pinyin.schema.yaml (不存在) → 判断恒失败 → 每次运行都
    #   删目录重装, 运行中的 fcitx5 被破坏导致无法打字 (实测事故)
    local RIME_DIR="${ACTUAL_HOME}/.local/share/fcitx5/rime"
    if [[ -f "$RIME_DIR/default.yaml" ]] && [[ -f "$RIME_DIR/rime_ice.schema.yaml" ]]; then
        info "Rime 雾凇: 已安装 (跳过)"
    elif [[ "$TEST_MODE" -eq 1 ]]; then
        # 测试模式: 不触碰真实 rime 目录 (备份/删除/克隆需真实网络, 防止误删)
        info "测试模式: 跳过雾凇安装 (需真实网络)"
    else
        info "安装 Rime 雾凇方案 (rime-ice)..."
        mkdir -p "$(dirname "$RIME_DIR")"
        # 备份仅在循环外移动一次, 循环内绝不删除备份 (曾因 rm -rf 备份导致
        # 克隆失败时把用户已有雾凇目录也抹掉)
        local RIME_BAK="${RIME_DIR}.bak.$$"
        local RIME_TRY=0 RIME_OK=0
        rm -rf "$RIME_BAK" 2>/dev/null
        [[ -d "$RIME_DIR" ]] && mv "$RIME_DIR" "$RIME_BAK" 2>/dev/null || true
        while (( RIME_TRY < 2 )); do
            (( RIME_TRY++ ))
            rm -rf "$RIME_DIR" 2>/dev/null
            # 直连失败自动走 gh-proxy.com 镜像
            if { su - "$ACTUAL_USER" -c "git clone --depth=1 https://github.com/iDvel/rime-ice.git '${RIME_DIR}'" >/dev/null 2>&1 \
                 || su - "$ACTUAL_USER" -c "git clone --depth=1 https://gh-proxy.com/https://github.com/iDvel/rime-ice.git '${RIME_DIR}'" >/dev/null 2>&1; } \
               && [[ -f "$RIME_DIR/default.yaml" ]]; then
                RIME_OK=1
                break
            fi
            rm -rf "$RIME_DIR" 2>/dev/null
            (( RIME_TRY < 2 )) && { info "雾凇拉取中断 (第 ${RIME_TRY} 次失败), 3s 后重试..."; sleep 3; }
        done
        if [[ "$RIME_OK" -eq 1 ]]; then
            info "✅ Rime 雾凇安装完成 (default 雾凇方案)"
            rm -rf "$RIME_BAK" 2>/dev/null || true
        else
            # 克隆失败: 恢复原目录 (绝不让用户已有配置丢失)
            [[ -d "$RIME_BAK" ]] && mv "$RIME_BAK" "$RIME_DIR" 2>/dev/null || true
            warn "Rime 雾凇拉取失败 (网络/代理不稳定), 请检查网络后手动重试:"
            warn "  sudo -u $ACTUAL_USER git clone --depth=1 https://github.com/iDvel/rime-ice.git '${RIME_DIR}'"
        fi
    fi

    # ── 项目自定义 Rime 配置覆盖 (任何分支都执行, 保证项目配置始终生效) ──
    # 来源: 项目 fcitx5/ 目录
    #   default.yaml: 替换 rime 下的 default.yaml (启用小鹤/雾凇/自然码三方案)
    #   *.custom.yaml: 复制添加 (各方案全拼提示 + 万象语法模型)
    # 注意: 仅真实模式执行; 测试模式不触碰 rime 目录
    if [[ "$TEST_MODE" -eq 0 ]] && [[ -d "$RIME_DIR" ]]; then
        local RIME_PROJ_DIR="${SCRIPT_DIR}/fcitx5"
        if [[ -d "$RIME_PROJ_DIR" ]]; then
            local RIME_PROJ_DEF="${RIME_PROJ_DIR}/default.yaml"
            if [[ -f "$RIME_PROJ_DEF" ]]; then
                cp -f "$RIME_PROJ_DEF" "$RIME_DIR/default.yaml" 2>/dev/null && \
                    info "✅ 已应用项目 default.yaml (小鹤/雾凇/自然码三方案)"
            else
                warn "未找到项目 fcitx5/default.yaml, 跳过"
            fi
            # 三方案 custom 补丁: 全拼提示 + 万象语法模型
            local RIME_CUSTOMS=(double_pinyin_flypy rime_ice double_pinyin)
            local _rc_name _rc_src
            for _rc_name in "${RIME_CUSTOMS[@]}"; do
                _rc_src="${RIME_PROJ_DIR}/${_rc_name}.custom.yaml"
                if [[ -f "$_rc_src" ]]; then
                    cp -f "$_rc_src" "$RIME_DIR/${_rc_name}.custom.yaml" 2>/dev/null && \
                        info "✅ 已添加 ${_rc_name}.custom.yaml (全拼提示+语法模型)"
                else
                    warn "未找到项目 fcitx5/${_rc_name}.custom.yaml, 跳过"
                fi
            done
        else
            warn "未找到项目 fcitx5/ 目录 (Rime 配置源), 跳过自定义配置"
        fi
        # 万象语法模型 (librime-octagram): 缺失时从 GitHub 下载
        local RIME_GRAM="$RIME_DIR/wanxiang-lts-zh-hans.gram"
        if [[ ! -f "$RIME_GRAM" ]]; then
            info "下载万象语法模型 (wanxiang-lts-zh-hans.gram)..."
            if gh_curl "https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram" \
                --connect-timeout 20 --max-time 600 > "$RIME_GRAM" \
               && [[ -s "$RIME_GRAM" ]]; then
                info "✅ 万象语法模型下载完成 ($(du -h "$RIME_GRAM" | cut -f1))"
            else
                rm -f "$RIME_GRAM" 2>/dev/null
                warn "万象语法模型下载失败 (可稍后手动下载放入 rime 目录)"
            fi
        else
            info "万象语法模型已存在 (跳过)"
        fi
        chown -R "$ACTUAL_USER:" "$RIME_DIR" 2>/dev/null || true
    fi

    # ── Node.js 26 ──
    if ! command -v node >/dev/null 2>&1; then
        info "安装 Node.js 26..."
        curl -fsSL --retry 3 https://rpm.nodesource.com/setup_26.x | bash - >/dev/null 2>&1 || true
        "$DNF" install -y nodejs 2>/dev/null || true
    else
        info "Node.js 已安装: $(node -v 2>/dev/null)"
    fi

    # ── VSCode ──
    if ! rpm -q code >/dev/null 2>&1; then
        info "安装 VSCode..."
        rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
        cat > /etc/yum.repos.d/vscode.repo <<'REPO'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPO
        "$DNF" install -y code 2>/dev/null || true
    fi

    # ── Chrome ──
    if ! rpm -q google-chrome-stable >/dev/null 2>&1; then
        info "安装 Google Chrome..."
        "$DNF" install -y fedora-workstation-repositories 2>/dev/null || true
        "$DNF" config-manager setopt google-chrome.enabled=1 2>/dev/null || true
        "$DNF" install -y google-chrome-stable 2>/dev/null || true
    fi

    # ── Telegram / Haruna (dnf) ──
    dnf_ensure telegram-desktop haruna kate

    # ── QQ / 微信 / ONLYOFFICE / Gopeed / ReadAny / VutronMusic / zed / MarkShot / ScrcpyGUI (RPM) ──
    install_direct_rpm "https://qqdl.gtimg.cn/qqfile/QQNT/9.9.33/release/c97651b2/QQ_3.2.32_260730_x86_64_01.rpm" "QQ" "linuxqq"
    install_direct_rpm "https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.rpm" "微信" "wechat"
    # GitHub 应用: 动态解析最新 release, 不写死版本号 (已装则跳过)
    install_github_rpm "ONLYOFFICE/DesktopEditors" "ONLYOFFICE" "onlyoffice-desktopeditors" "onlyoffice-desktopeditors\.x86_64\.rpm$"
    install_github_rpm "GopeedLab/gopeed" "Gopeed" "gopeed" "linux-amd64.*\.rpm$"
    install_github_rpm "codedogQBY/ReadAny" "ReadAny" "read-any" "x86_64.*\.rpm$"
    install_github_rpm "stark81/VutronMusic" "VutronMusic" "VutronMusic" "linux_x86_64.*\.rpm$"
    install_github_rpm "x6nux/zed-globalization" "zed-globalization" "zedg" "linux-x86_64.*\.rpm$"
    install_github_rpm "jswysnemc/mark-shot" "Mark Shot" "mark-shot" "fedora_x86_64.*\.rpm$"
    install_github_rpm "kil0bit-kb/scrcpy-gui" "ScrcpyGUI" "Scrcpy GUI" "x86_64.*\.rpm$"

    # ── KVM/QEMU ──
    info "安装 KVM/QEMU..."
    dnf_ensure @virtualization virt-manager libvirt qemu-kvm
    systemctl enable --now libvirtd 2>/dev/null || true
    usermod -aG libvirt "$ACTUAL_USER" 2>/dev/null || true

    if command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --zone=libvirt --add-service=libvirt 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi

    # ═══════════ 命令安装 ═══════════
    # ── opencode (双方式: 官方脚本 → 桌面端 RPM) ──
    # 官方安装器路径: ~/.opencode/bin/opencode (命令版)
    # 桌面端 RPM: rpm 包 opencode, 数据在 ~/.config
    # 首次执行先判断是否已有命令版 opencode, 有则询问是否补装桌面端;
    # 无则先试官方安装脚本 (方式一), 失败自动转桌面端 RPM (方式二)。
    local OC_CLI_BIN="${ACTUAL_HOME}/.opencode/bin/opencode"
    local OC_HAS_CLI=0 OC_NEED_DESKTOP=0
    [[ -x "$OC_CLI_BIN" ]] && OC_HAS_CLI=1
    [[ -d "${ACTUAL_HOME}/.opencode" ]] && OC_HAS_CLI=1

    if rpm -q opencode >/dev/null 2>&1; then
        info "✅ opencode 桌面端 (RPM) 已安装"
    elif [[ "$OC_HAS_CLI" -eq 1 ]]; then
        info "检测到命令行版 opencode (~/.opencode/bin/opencode)"
        local oc_ans=""
        read -r -t 30 -p "是否同时安装 opencode 桌面端 (RPM)? [y/N] " oc_ans || oc_ans=""
        case "$oc_ans" in
            y|Y|yes) OC_NEED_DESKTOP=1 ;;
            *) info "跳过 opencode 桌面端安装" ;;
        esac
    else
        info "安装 opencode (方式一: 官方安装脚本)..."
        # 官方脚本需 api.github.com 取版本号(网络/代理不稳会失败 → "Failed to
        # fetch version information"); 改经 /releases/latest 的 Location 重定向解析
        # 最新版本(纯 github.com), 再以 export VERSION= 传回官方脚本使其跳过 API。
        local OC_VER="" OC_ATTEMPT=0 OC_OK=0
        OC_VER=$(gh_curl "https://github.com/anomalyco/opencode/releases/latest" \
            -fsSI --max-time 15 \
            | tr -d '\r' | sed -n 's#.*[Tt]ag/[vV]\([0-9][0-9.]*\).*#\1#p' | head -1)
        if [[ -n "$OC_VER" ]]; then
            while (( OC_ATTEMPT < 2 )); do
                (( OC_ATTEMPT++ ))
                if su - "$ACTUAL_USER" -c "export VERSION='${OC_VER}' && curl -fsSL https://opencode.ai/install | bash" 2>/dev/null \
                   && [[ -x "$OC_CLI_BIN" ]]; then
                    OC_OK=1
                    break
                fi
                (( OC_ATTEMPT < 2 )) && { info "opencode 方式一中断 (第 ${OC_ATTEMPT} 次失败), 3s 后重试..."; sleep 3; }
            done
        fi
        if [[ "$OC_OK" -eq 1 ]]; then
            info "✅ opencode v$OC_VER (CLI) 已安装 ($OC_CLI_BIN)"
            # 确保 PATH 含 ~/.opencode/bin (官方安装器写的 .zshrc 会被本脚本覆盖,
            # 需显式写入 .zshrc/.profile)
            for _rc in "$ACTUAL_HOME/.zshrc" "$ACTUAL_HOME/.bash_profile" "$ACTUAL_HOME/.profile"; do
                if [[ -f "$_rc" ]] && ! grep -q '\.opencode/bin' "$_rc" 2>/dev/null; then
                    printf '\n# opencode CLI\nexport PATH="$HOME/.opencode/bin:$PATH"\n' >> "$_rc"
                    chown "$ACTUAL_USER:" "$_rc" 2>/dev/null || true
                fi
            done
        else
            warn "方式一 (官方脚本) 失败, 转方式二: 安装 opencode 桌面端 (RPM)..."
            OC_NEED_DESKTOP=1
        fi
    fi

    # 方式二: opencode 桌面端 RPM (直链稳定, 不受脚本网络限制影响)
    if [[ "$OC_NEED_DESKTOP" -eq 1 ]] && ! rpm -q opencode >/dev/null 2>&1; then
        local OC_RPM_URL="https://opencode.ai/zh/download/stable/linux-x64-rpm"
        local OC_RPM_OK=0 OC_RTRY=0
        while (( OC_RTRY < 2 )); do
            (( OC_RTRY++ ))
            if curl -fL --retry 2 --connect-timeout 20 -o /tmp/opencode.rpm "$OC_RPM_URL" 2>/dev/null \
               && "$DNF" install -y /tmp/opencode.rpm 2>/dev/null; then
                OC_RPM_OK=1
                break
            fi
            (( OC_RTRY < 2 )) && { info "opencode RPM 安装失败 (第 ${OC_RTRY} 次), 3s 后重试..."; sleep 3; }
        done
        rm -f /tmp/opencode.rpm 2>/dev/null
        if [[ "$OC_RPM_OK" -eq 1 ]]; then
            info "✅ opencode 桌面端 (RPM) 已安装"
        else
            warn "opencode 桌面端安装失败, 可手动重试:"
            warn "  curl -fL -O https://opencode.ai/zh/download/stable/linux-x64-rpm && sudo dnf install -y linux-x64-rpm"
        fi
    fi

    # ── Anki (tar.zst) ──
    if ! command -v anki >/dev/null 2>&1; then
        info "安装 Anki..."
        gh_curl "https://github.com/ankitects/anki/releases/download/26.08/anki-26.08-linux-x86_64.tar.zst" \
            --connect-timeout 20 > /tmp/anki.tar.zst && {
            rm -rf /tmp/anki-extract
            mkdir -p /tmp/anki-extract
            tar -xf /tmp/anki.tar.zst -C /tmp/anki-extract 2>/dev/null
            ( cd /tmp/anki-extract/anki-* 2>/dev/null && ./install.sh 2>/dev/null ) || true
        }
        rm -rf /tmp/anki.tar.zst /tmp/anki-extract
    fi

    # ═══════════ Flatpak 安装 ═══════════
    # MissionCenter 运行时依赖: nethogs(网络流量) + lm_sensors(传感器检测),
    # 缺失时其 magpie 组件报 "Nethogs not found / sensors-detect not found"
    dnf_ensure nethogs lm_sensors
    # 逐个安装: 先确保 flathub 远端存在, 每包独立判断已装状态与结果,
    # 避免整批失败被静默吞掉 (曾因 LocalSend 包名错误导致全部未装)
    if ! flatpak remotes 2>/dev/null | grep -q flathub; then
        info "添加 flathub 远端..."
        flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null \
            || warn "flathub 远端添加失败 (需手动: flatpak remote-add flathub https://flathub.org/repo/flathub.flatpakrepo)"
    fi
    info "安装 Flatpak 应用 (逐个判断, 已装跳过)..."
    local FP_APPS=(
        "io.typora.Typora"           "Typora"
        "org.localsend.localsend_app" "LocalSend"   # 注意: 包名是 org.localsend.localsend_app
        "it.mijorus.gearlever"       "Gear Lever"
        "io.missioncenter.MissionCenter" "Mission Center"
        "io.github.fabrialberio.pinapp" "PinApp"
    )
    local FP_ID FP_NAME FP_APP FP_OK=0 FP_FAILED=()
    for (( FP_ID = 0; FP_ID < ${#FP_APPS[@]}; FP_ID += 2 )); do
        FP_APP="${FP_APPS[$FP_ID]}"
        FP_NAME="${FP_APPS[$((FP_ID + 1))]}"
        if flatpak info "$FP_APP" >/dev/null 2>&1; then
            info "✅ $FP_NAME ($FP_APP): 已安装 (跳过)"
        elif flatpak install -y flathub "$FP_APP" >/dev/null 2>&1; then
            info "✅ $FP_NAME ($FP_APP): 安装完成"
            FP_OK=$((FP_OK + 1))
        else
            warn "❌ $FP_NAME ($FP_APP): 安装失败"
            FP_FAILED+=("$FP_APP")
        fi
    done
    [[ ${#FP_FAILED[@]} -gt 0 ]] && \
        warn "Flatpak 安装失败 ${#FP_FAILED[@]} 个: ${FP_FAILED[*]} (可稍后手动: flatpak install flathub ${FP_FAILED[*]})"

    # Flatpak 应用中文界面: 系统 LANG=zh_CN.UTF-8 但部分应用 (如 MissionCenter)
    # 启动时拿不到 → 用 flatpak override 按应用固定注入中文环境变量
    if flatpak info io.missioncenter.MissionCenter >/dev/null 2>&1; then
        flatpak override --user --env=LANG=zh_CN.UTF-8 --env=LC_ALL=zh_CN.UTF-8 \
            io.missioncenter.MissionCenter 2>/dev/null || true
        info "✅ MissionCenter 已注入中文环境 (flatpak override)"
    fi

    info "✅ 应用安装完成"
}

# ============================================================================
#  7/7  32位库 + Steam (可选模块)
# ============================================================================
setup_steam() {
    step "7/7 32位库 + Steam (可选模块)"

    info "安装 32 位兼容库 (只装缺失的, 已装自动跳过)..."
    dnf_ensure glibc.i686 libstdc++.i686 libgcc.i686 vulkan-loader.i686 \
        alsa-lib.i686 pipewire-alsa.i686 pipewire-libs.i686 pulseaudio-libs.i686 \
        openal-soft.i686 libXcomposite.i686 libXcursor.i686 libXdamage.i686 \
        libXext.i686 libXfixes.i686 libXi.i686 libXrandr.i686 libXrender.i686 libXtst.i686 || true

    info "安装 Steam..."
    if ! rpm -q steam >/dev/null 2>&1; then
        "$DNF" install -y steam 2>/dev/null || warn "Steam 安装失败"
    fi

    info "✅ Steam 环境就绪"
}

# ============================================================================
#  main
# ============================================================================
main() {
    # ── 流程日志: 全程输出写入用户文档目录 (方便事后查改) ──
    local LOG_DIR LOG_FILE
    LOG_DIR="${ACTUAL_HOME}/文档/fedora-forge-logs"
    [[ -d "${ACTUAL_HOME}/文档" ]] || LOG_DIR="${ACTUAL_HOME}/Documents/fedora-forge-logs"
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/fedora-forge-logs"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    LOG_FILE="${LOG_DIR}/fedora-forge-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$LOG_FILE") 2>&1
    chown "$ACTUAL_USER" "$LOG_DIR" "$LOG_FILE" 2>/dev/null || true
    echo -e "${CYAN}📄 流程日志: ${LOG_FILE}${NC}"
    echo -e "${BOLD}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║       Fedora Forge 全面初始化脚本 v4.3       ║"
    echo "  ║            KDE Plasma Edition               ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"

    # 版本范围检查: 本脚本针对 Fedora 42-44 设计与测试
    if (( FEDORA_VER < 42 )); then
        die "本脚本支持 Fedora 42-44, 当前为 Fedora $FEDORA_VER, 请升级系统后再运行"
    elif (( FEDORA_VER > 44 )); then
        warn "当前为 Fedora $FEDORA_VER (脚本测试于 42-44), 如遇包名/配置变化请反馈"
    fi

    # 网络检测: 新装机无网络时给出明确提示 (跳过测试模式)
    if [[ "$TEST_MODE" -ne 1 ]] && ! curl -fs --connect-timeout 5 https://fedoraproject.org >/dev/null 2>&1; then
        die "网络不可用 (无法访问 fedoraproject.org), 请检查网络连接后重试"
    fi

    info "将执行以下模块:"
    # 单模块执行时跳过系统升级检查 (冗余); 仅全量(-all/无参数)运行
    local DO_UPGRADE=0
    if [[ "$RUN_UPGRADE" -eq 1 && ( "$HAS_MODULE" -eq 0 || "$RUN_ALL" -eq 1 ) ]]; then
        DO_UPGRADE=1
    fi
    [[ "$RUN_SOURCE" -eq 1 ]] && echo -e "  ${GREEN}✓${NC} 软件源优化"
    [[ "$DO_UPGRADE" -eq 1 ]] && echo -e "  ${GREEN}✓${NC} 系统升级检查 ${YELLOW}(全量升级+重启检测)${NC}"
    [[ "$RUN_GPU" -eq 1 ]]    && echo -e "  ${GREEN}✓${NC} CPU/GPU驱动 + 电源方案(默认/auto-cpufreq) + 解码"
    [[ "$RUN_TERM" -eq 1 ]]   && echo -e "  ${GREEN}✓${NC} 终端配置"
    [[ "$RUN_THEME" -eq 1 ]]  && echo -e "  ${GREEN}✓${NC} 主题 & 系统优化 (含 NM 优化)"
    [[ "$RUN_APPS" -eq 1 ]]   && echo -e "  ${GREEN}✓${NC} 应用管理"
    [[ "$RUN_STEAM" -eq 1 ]]  && echo -e "  ${GREEN}✓${NC} 32位库 + Steam ${YELLOW}(可选模块)${NC}"
    echo ""
    [[ "$DO_UPGRADE" -eq 1 ]] && echo -e "  ${YELLOW}注意: 若检测到可用更新, 将先全量升级; 升级内核后需重启并再次运行脚本${NC}"
    echo ""
    echo -e "  按 ${YELLOW}Ctrl+C${NC} 取消, 或等待 5 秒后自动开始..."
    sleep 5

    wait_rpm

    [[ "$RUN_SOURCE" -eq 1 ]] && optimize_sources
    [[ "$DO_UPGRADE" -eq 1 ]] && system_upgrade_check
    [[ "$RUN_GPU" -eq 1 ]]    && optimize_gpu
    [[ "$RUN_TERM" -eq 1 ]]   && setup_terminal
    [[ "$RUN_THEME" -eq 1 ]]  && apply_theme
    [[ "$RUN_APPS" -eq 1 ]]   && manage_apps
    [[ "$RUN_STEAM" -eq 1 ]]  && setup_steam


    # ═══════════ 清理═══════════
    info "清理临时文件..."
    rm -rf /tmp/anki.tar.zst /tmp/anki-extract /tmp/opencode.rpm /tmp/starship.tar.gz /tmp/oc.tar.gz /tmp/opencode 2>/dev/null || true

    echo ""
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  ✅ 全部完成!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  📄 本次完整流程日志已保存 (含每一步操作明细):${NC}"
    echo -e "${CYAN}     ${LOG_FILE}${NC}"
    echo -e "${CYAN}──────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  重启后验证:"
    echo -e "  • NVIDIA:       ${CYAN}nvidia-smi${NC}"
    echo -e "  • auto-cpufreq: ${CYAN}auto-cpufreq --stats${NC}"
    echo -e "  • 输入法:       KDE 系统设置 → 虚拟键盘 → Fcitx5"
    [[ "$RUN_STEAM" -eq 1 ]] && echo -e "  • Steam:        ${CYAN}steam${NC}"
    echo -e "  • KVM:          ${CYAN}virt-manager${NC}"
    echo -e "  • SELinux:      ${CYAN}getenforce${NC} (应为 Permissive)"
    if [[ "$RUN_TERM" -eq 1 ]] && [[ -f "${ACTUAL_HOME}/.config/kitty/kitty-theme.sh" ]]; then
        echo -e "  • Kitty 主题:   ${CYAN}~/.config/kitty/kitty-theme.sh${NC} 弹出 rofi 选择主题"
    fi
    echo ""

    # 重启提醒: 本次配置涉及内核/驱动/服务变更, 必须重启一次才能完整生效
    # (不自动重启, 由用户手动执行; 测试模式仅提示)
    echo ""
    if [[ "$TEST_MODE" -eq 1 ]]; then
        echo -e "${YELLOW}测试模式: 跳过重启提醒${NC}"
    else
        echo -e "${RED}${BOLD}═══════════════════════════════════════════════${NC}"
        echo -e "${RED}${BOLD}  ⚠ 重要: 系统必须重启一次才能完整生效!${NC}"
        echo -e "${RED}${BOLD}═══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  请手动执行: ${CYAN}sudo reboot${NC}"
        echo -e "${YELLOW}  重启后如有未生效项, 再次运行本脚本即可 (已配置项会自动跳过)${NC}"
    fi
}

# ────────────────────────────────────────────── 测试模式拦截 (位于所有函数定义之后)
# 覆盖 dnf/flatpak/curl/su/reboot 为无害行为, 防止测试时误操作真实系统
if [[ "$TEST_MODE" -eq 1 ]]; then
    info "⚠ 测试模式: 所有安装/下载/重启操作将被跳过"
    DNF=true
    dnf_install_quiet() { info "  [TEST] dnf 安装跳过: $*"; }
    dnf_ensure() { info "  [TEST] dnf 检查跳过: $*"; }
    wait_rpm() { :; }
    # flatpak: info(已装检查) 模拟已安装返回 0, install 模拟失败返回 1
    # → 测试可真实演练"已装跳过"幂等路径, 且不会真装包
    flatpak() {
        if [[ "$1" == "info" ]]; then
            info "  [TEST] flatpak info 跳过: $*"; return 0
        fi
        info "  [TEST] flatpak 跳过: $*"; return 1
    }
    systemctl() { info "  [TEST] systemctl 跳过: $*"; }
    reboot() { info "  [TEST] reboot 跳过"; }
    shutdown() { info "  [TEST] shutdown 跳过"; }
    curl() { info "  [TEST] curl 跳过: $*"; }
    su() { info "  [TEST] su 跳过: $*"; }
    pipx() { info "  [TEST] pipx 跳过: $*"; }
fi

main "$@"
