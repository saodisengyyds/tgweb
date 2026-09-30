#!/bin/sh
# tgweb 一键安装 / 管理菜单（中文交互式）
#
# 用法：sh setup.sh
#   - 未安装时：走「全新安装」向导（检测系统 → 提示装依赖 → 拉取安装包 → 填配置）
#   - 已安装时：管理菜单（改配置 / 看状态 / 看日志 / 测试推送 / 重启 / 卸载）
#
# 安装包来源：优先用同目录下的 tgweb-nat-linux-amd64.tar.gz，
# 否则从 GitHub Releases 下载（把安装包传到你仓库的 Releases 即可）。
set -u

# ============ 改成你自己的 GitHub 仓库（用户名/仓库名）============
REPO="saodisengyyds/tgweb"
# =================================================================
PKG_NAME="tgweb-nat-linux-amd64.tar.gz"
PKG_URL="${PKG_URL:-https://github.com/${REPO}/releases/latest/download/${PKG_NAME}}"

ASK_A=""
DOWNLOAD_PKG=""

# ---------- 小工具 ----------
ask() {  # $1=提示文字 $2=默认值（可空）
    if [ -n "${2:-}" ]; then
        printf '%s [%s]: ' "$1" "$2"
    else
        printf '%s: ' "$1"
    fi
    read -r ASK_A
    [ -n "$ASK_A" ] || ASK_A="${2:-}"
}

confirm() {  # $1=提示；返回 0=是
    printf '%s [Y/n]: ' "$1"
    read -r _yn
    case "$_yn" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
}

get_conf() {  # $1=KEY $2=文件
    sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1 | tr -d '\r\n'
}

detect_base() {  # 已安装则输出安装目录
    if [ -n "${TGWEB_BASE:-}" ] && [ -f "$TGWEB_BASE/tgweb.sh" ]; then
        printf '%s' "$TGWEB_BASE"; return 0
    fi
    if [ -f /root/tgweb/tgweb.sh ]; then printf '/root/tgweb'; return 0; fi
    if [ -n "${HOME:-}" ] && [ -f "$HOME/tgweb/tgweb.sh" ]; then
        printf '%s' "$HOME/tgweb"; return 0
    fi
    return 1
}

# ---------- 系统检测与依赖 ----------
detect_os() {
    if [ -f /etc/alpine-release ]; then echo alpine; return 0; fi
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|raspbian|linuxmint|pop) echo debian ;;
            centos|rhel|rocky|almalinux|fedora|ol) echo rhel ;;
            arch|manjaro) echo arch ;;
            *) echo unknown ;;
        esac
        return 0
    fi
    echo unknown
}

# 输出缺失的依赖（空格分隔），$1=系统类型
check_deps() {
    _m=""
    command -v curl >/dev/null 2>&1 || _m="$_m curl"
    command -v pgrep >/dev/null 2>&1 || _m="$_m procps"
    command -v tar >/dev/null 2>&1 || _m="$_m tar"
    if [ "$1" = "alpine" ]; then
        # gcompat 是库（提供 /lib/ld-linux-x86-64.so.2），没有可执行文件，
        # 不能用 command -v 检测
        { [ -e /lib/ld-linux-x86-64.so.2 ] || [ -e /lib64/ld-linux-x86-64.so.2 ]; } \
            || _m="$_m gcompat"
    fi
    printf '%s' "$_m" | sed 's/^ //'
}

install_deps() {
    _os="$(detect_os)"
    _missing="$(check_deps "$_os")"
    if [ -z "$_missing" ]; then
        echo "检测到系统: $_os，依赖齐全。"
        return 0
    fi
    echo "检测到系统: $_os"
    echo "缺失依赖: $_missing"
    echo "  curl    —— 下载安装包、健康检查、TG 推送都要用"
    echo "  procps  —— pgrep/pkill，保活脚本管理进程用"
    echo "  tar     —— 下载后校验、解压安装包"
    [ "$_os" = "alpine" ] && echo "  gcompat —— Alpine 跑 glibc 版 cloudflared 需要"
    confirm "是否现在自动安装？" || { echo "已跳过，请手动安装后再继续。"; return 1; }
    _sudo=""
    if [ "$(id -u)" != "0" ]; then
        if command -v sudo >/dev/null 2>&1; then
            _sudo="sudo"
        else
            echo "需要 root 权限（或 sudo）来安装软件包，请用 root 运行或手动安装: $_missing"
            return 1
        fi
    fi
    # 只装确实缺的包
    _pkgs=""
    for _d in $_missing; do
        case "$_d" in
            curl) _pkgs="$_pkgs curl" ;;
            procps)
                case "$_os" in rhel|arch) _pkgs="$_pkgs procps-ng" ;; *) _pkgs="$_pkgs procps" ;; esac ;;
            tar) _pkgs="$_pkgs tar" ;;
            gcompat) _pkgs="$_pkgs gcompat" ;;
        esac
    done
    _pkgs="$(printf '%s' "$_pkgs" | sed 's/^ //')"
    case "$_os" in
        alpine) $_sudo apk add --no-cache $_pkgs ;;
        debian) $_sudo apt-get update && $_sudo apt-get install -y $_pkgs ;;
        rhel)
            if command -v dnf >/dev/null 2>&1; then
                $_sudo dnf install -y $_pkgs
            else
                $_sudo yum install -y $_pkgs
            fi ;;
        arch) $_sudo pacman -Sy --noconfirm $_pkgs ;;
        *) echo "未知系统，请手动安装: $_missing"; return 1 ;;
    esac || { echo "依赖安装失败，请手动安装: $_missing"; return 1; }
    # 装完复检，缺的必须真装上才继续
    _missing="$(check_deps "$_os")"
    if [ -n "$_missing" ]; then
        echo "安装后仍缺失: $_missing，请手动安装后再继续。"
        return 1
    fi
    echo "依赖已就绪。"
}

# ---------- 安装包 ----------
# 优先用本地的包；没有则稍后从 GitHub 流式下载（curl | tar 直接解压，
# 不存 34MB 中间文件，省磁盘空间/配额）
download_pkg() {
    DOWNLOAD_PKG=""
    for _c in "./$PKG_NAME" "${HOME:-/root}/$PKG_NAME" "/tmp/$PKG_NAME"; do
        if [ -f "$_c" ]; then
            if tar tzf "$_c" >/dev/null 2>&1; then
                echo "使用本地安装包: $_c"
                DOWNLOAD_PKG="$_c"
                return 0
            fi
            echo "本地安装包已损坏，忽略: $_c"
        fi
    done
    case "$REPO" in
        username/*)
            echo "注意：脚本顶部的 REPO 还是占位符（username/tgweb），请先改成你自己的 GitHub 仓库。"
            echo "或者把 $PKG_NAME 放到当前目录再运行本脚本。"
            return 1 ;;
    esac
    command -v curl >/dev/null 2>&1 || { echo "缺少 curl，无法下载。"; return 1; }
    echo "安装时将从 GitHub Releases 流式下载并解压（不占中间空间）："
    echo "  $PKG_URL"
    return 0
}

# ---------- 保活 ----------
setup_keepalive() {  # $1=安装目录
    _base="$1"
    if [ -f /etc/alpine-release ] && command -v rc-update >/dev/null 2>&1; then
        rc-update add crond default 2>/dev/null
        rc-service crond start 2>/dev/null || service crond start 2>/dev/null
    fi
    if [ "$(id -u)" = "0" ] && [ -d /run/systemd/system ]; then
        cat > /etc/systemd/system/tgweb.service <<EOF
[Unit]
Description=tgweb Telegram proxy keepalive tick
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=TGWEB_BASE=$_base
ExecStart=/bin/sh $_base/tgweb.sh
EOF
        cat > /etc/systemd/system/tgweb.timer <<EOF
[Unit]
Description=run tgweb keepalive every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload && systemctl enable --now tgweb.timer
        echo "已安装 systemd timer 保活（每分钟）。"
    else
        _cron="* * * * * TGWEB_BASE=$_base sh $_base/tgweb.sh"
        if command -v crontab >/dev/null 2>&1; then
            if ! crontab -l 2>/dev/null | grep -qF "$_base/tgweb.sh"; then
                (crontab -l 2>/dev/null; echo "$_cron") | crontab -
            fi
            echo "已安装 cron 保活（每分钟）。"
        else
            echo "没有 crontab，请手动添加：$_cron"
        fi
    fi
}

# ---------- 写配置 ----------
write_conf() {  # 用全局 _host _token _listen _rport _mport _aport _bt _cid _secret _mode 写 $BASE/tgweb.conf
    {
        printf '# tgweb 配置文件（由 setup.sh 生成，也可手动编辑）\n'
        if [ "$_mode" = "1" ]; then
            printf '# 连接方式：cloudflare tunnel\n'
        else
            printf '# 连接方式：direct（公网直连）\n'
        fi
        printf 'RELAY_PORT=%s\n' "$_rport"
        printf 'MTG_PORT=%s\n' "$_mport"
        printf 'ADMIN_PORT=%s\n' "$_aport"
        printf 'RELAY_LISTEN=%s\n' "$_listen"
        printf 'TGWEB_HOST=%s\n' "$_host"
        printf 'TUNNEL_TOKEN=%s\n' "$_token"
        printf 'BOT_TOKEN=%s\n' "$_bt"
        printf 'CHAT_ID=%s\n' "$_cid"
        printf 'SECRET=%s\n' "$_secret"
    } > "$BASE/tgweb.conf"
    chmod 600 "$BASE/tgweb.conf"
    echo "配置已写入 $BASE/tgweb.conf"
}

check_port() {  # $1=值 $2=默认值 → 输出合法端口
    case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

# ---------- 全新安装 ----------
do_install() {
    if detect_base >/dev/null 2>&1; then
        echo "检测到已安装（$(detect_base)），请用下面的管理菜单操作。"
        return 1
    fi
    echo "====== 步骤 1/5：系统检测与依赖 ======"
    install_deps || return 1
    echo "====== 步骤 2/5：获取安装包 ======"
    download_pkg || return 1
    echo "====== 步骤 3/5：安装位置 ======"
    if [ "$(id -u)" = "0" ]; then _def_base=/root/tgweb; else _def_base="${HOME:-/tmp}/tgweb"; fi
    ask "安装目录" "$_def_base"; BASE="$ASK_A"
    case "$BASE" in ""|"/") echo "安装目录不合法。"; return 1 ;; esac
    export TGWEB_BASE="$BASE"  # 让本脚本后续的 detect_base 能找到刚装好的目录
    # 先确认目录建得出来、空间够（流式解压约需 80MB），免得填完一堆配置才失败
    _parent="$(dirname "$BASE")"
    if [ ! -d "$_parent" ]; then echo "父目录不存在: $_parent"; return 1; fi
    _av="$(df -k "$_parent" 2>/dev/null | awk 'NR==2{print $4}')"
    case "$_av" in ''|*[!0-9]*) _av=0 ;; esac
    if [ "$_av" -lt 81920 ] || ! mkdir -p "$BASE" 2>/dev/null; then
        echo "安装目录不可用: $BASE"
        echo "  磁盘空间/配额不足（比如 Quota exceeded），安装约需 80MB。"
        df -h "$_parent" 2>/dev/null
        echo "  排查：du -sh ${_parent}/* 2>/dev/null | sort -rh | head"
        echo "  清理出空间后再运行本脚本。"
        return 1
    fi
    echo "====== 步骤 4/5：连接方式 ======"
    echo "  1) Cloudflare Tunnel（推荐）——NAT 机、没有公网端口的机器用这个，"
    echo "     cloudflared 向外连 Cloudflare，防火墙什么都不用开"
    echo "  2) 直连——机器有公网 IP，Telegram 直接连你的机器，"
    echo "     需要在防火墙/安全组放行 relay 端口"
    ask "请选择" "1"; _mode="$ASK_A"
    echo "====== 步骤 5/5：填写配置（直接回车用默认值）======"
    ask "公网域名（tunnel 填 CF 上的 hostname；直连填域名或公网 IP）" "tg.example.com"
    _host="$ASK_A"
    if [ "$_mode" = "2" ]; then
        _token=""
        _def_listen="0.0.0.0"
        echo "直连模式：TUNNEL_TOKEN 留空，cloudflared 不会启动。"
    else
        _mode="1"
        ask "Cloudflare tunnel token（CF 后台 Zero Trust → Networks → Tunnels 里复制）" ""
        _token="$ASK_A"
        _def_listen="127.0.0.1"
    fi
    ask "relay 监听地址（tunnel 用 127.0.0.1，直连用 0.0.0.0）" "$_def_listen"
    _listen="$ASK_A"
    ask "relay 端口" "18547";      _rport="$(check_port "$ASK_A" 18547)"
    ask "mtg 后端端口" "17349";     _mport="$(check_port "$ASK_A" 17349)"
    ask "管理端口" "56462";        _aport="$(check_port "$ASK_A" 56462)"
    ask "Telegram bot token（可选，用于推送代理链接，回车跳过）" ""; _bt="$ASK_A"
    ask "Telegram chat id（可选，回车跳过）" "";                          _cid="$ASK_A"
    ask "代理 SECRET（可选，32 位 hex，回车自动生成）" "";                _secret="$ASK_A"
    echo ""
    echo "配置确认："
    echo "  安装目录: $BASE"
    echo "  连接方式: $([ "$_mode" = "1" ] && echo 'Cloudflare Tunnel' || echo '直连')"
    echo "  域名: $_host  监听: $_listen  端口: relay=$_rport mtg=$_mport admin=$_aport"
    echo "  bot 推送: $([ -n "$_bt" ] && echo '已配置' || echo '未配置（跳过）')"
    confirm "开始安装？" || { echo "已取消。"; return 1; }
    mkdir -p "$BASE" || { echo "无法创建 $BASE"; return 1; }
    if [ -n "$DOWNLOAD_PKG" ]; then
        tar -xzf "$DOWNLOAD_PKG" -C "$BASE" || { echo "解压安装包失败"; return 1; }
    else
        echo "正在下载并解压安装包（约 33MB，请稍候）..."
        if curl -fSL --retry 2 "$PKG_URL" | tar -xz -C "$BASE"; then
            :
        else
            echo "下载/解压失败。检查：1) 仓库 $REPO 的 Releases 里有没有 $PKG_NAME；"
            echo "  2) 本机能否访问 github.com；3) 磁盘空间/配额是否足够（df -h 看一下）；"
            echo "  4) 也可以在电脑上下载好 $PKG_NAME，传到这台机器当前目录再运行。"
            return 1
        fi
    fi
    if [ ! -x "$BASE/bin/tproxy-server" ] || [ ! -f "$BASE/tgweb.sh" ]; then
        echo "安装包不完整（缺少关键文件），请重试或手动放包再运行。"
        return 1
    fi
    chmod +x "$BASE/bin/tproxy-server" "$BASE/bin/mtg" "$BASE/bin/cloudflared" 2>/dev/null
    write_conf
    setup_keepalive "$BASE"
    echo "首次启动..."
    TGWEB_BASE="$BASE" sh "$BASE/tgweb.sh"
    sleep 2
    echo ""
    do_status
    echo ""
    echo "安装完成！日志看：$BASE/var/k.log"
    if [ -n "$_bt" ]; then
        echo "relay 启动后代理链接会自动推送到你的 bot（约 1 分钟内）。"
    else
        echo "没有配置 bot token，需要链接时从 $BASE/var/secret.txt 取 secret 拼："
        echo "  https://t.me/webproxy?server=$_host&secret=<secret>"
    fi
    if [ "$_mode" = "1" ]; then
        echo "别忘了在 CF 后台给 tunnel 加 Public Hostname：$_host → http://127.0.0.1:$_rport"
    else
        echo "直连模式：请在防火墙/安全组放行 TCP 端口 $_rport。"
    fi
}

# ---------- 修改配置 ----------
do_edit_conf() {
    BASE="$(detect_base)" || { echo "未检测到安装，先执行「全新安装」。"; return 1; }
    _cf="$BASE/tgweb.conf"
    _host="$(get_conf TGWEB_HOST "$_cf")"
    _token="$(get_conf TUNNEL_TOKEN "$_cf")"
    _listen="$(get_conf RELAY_LISTEN "$_cf")";   [ -n "$_listen" ] || _listen=127.0.0.1
    _rport="$(get_conf RELAY_PORT "$_cf")";      [ -n "$_rport" ] || _rport=18547
    _mport="$(get_conf MTG_PORT "$_cf")";        [ -n "$_mport" ] || _mport=17349
    _aport="$(get_conf ADMIN_PORT "$_cf")";      [ -n "$_aport" ] || _aport=56462
    _bt="$(get_conf BOT_TOKEN "$_cf")"
    _cid="$(get_conf CHAT_ID "$_cf")"
    _secret="$(get_conf SECRET "$_cf")"
    if [ -n "$_token" ]; then _mode="1"; else _mode="2"; fi
    echo "当前配置（直接回车保持不变）："
    echo "  域名: ${_host:-未设置}"
    echo "  连接方式: $([ "$_mode" = "1" ] && echo 'Cloudflare Tunnel' || echo '直连')"
    echo "  监听: $_listen  端口: relay=$_rport mtg=$_mport admin=$_aport"
    echo "  bot: $([ -n "$_bt" ] && echo '已配置' || echo '未配置')"
    echo ""
    ask "公网域名" "$_host"; _host="$ASK_A"
    echo "连接方式：1) Cloudflare Tunnel  2) 直连"
    ask "请选择（回车保持当前）" "$_mode"; _mode="$ASK_A"
    if [ "$_mode" = "2" ]; then
        if [ -n "$_token" ]; then
            echo "切换到直连模式，清空 TUNNEL_TOKEN（cloudflared 将停止）。"
            _token=""
        fi
        _def_listen="0.0.0.0"
    else
        _mode="1"
        if [ -z "$_token" ]; then
            ask "Cloudflare tunnel token" ""; _token="$ASK_A"
        else
            ask "Cloudflare tunnel token（回车保持，输入 clear 清空）" "***已设置***"
            case "$ASK_A" in "***已设置***") ;; clear) _token="" ;; *) _token="$ASK_A" ;; esac
        fi
        _def_listen="127.0.0.1"
    fi
    [ -n "$_listen" ] || _listen="$_def_listen"
    ask "relay 监听地址" "$_listen";  _listen="$ASK_A"
    ask "relay 端口" "$_rport";       _rport="$(check_port "$ASK_A" "$_rport")"
    ask "mtg 后端端口" "$_mport";     _mport="$(check_port "$ASK_A" "$_mport")"
    ask "管理端口" "$_aport";         _aport="$(check_port "$ASK_A" "$_aport")"
    ask "Telegram bot token（回车保持，输入 clear 清空）" "$([ -n "$_bt" ] && echo '***已设置***' || echo '')"
    case "$ASK_A" in "***已设置***") ;; clear) _bt="" ;; *) _bt="$ASK_A" ;; esac
    ask "Telegram chat id" "$_cid";  _cid="$ASK_A"
    ask "代理 SECRET（回车保持，输入 clear 则下次自动生成新的）" "$([ -n "$_secret" ] && echo '***已设置***' || echo '')"
    case "$ASK_A" in "***已设置***") ;; clear) _secret="" ;; *) _secret="$ASK_A" ;; esac
    write_conf
    if confirm "是否立即重启使配置生效？"; then
        do_restart
    else
        echo "配置将在下次保活 tick（1 分钟内）自动生效。"
    fi
}

# ---------- 状态 ----------
do_status() {
    BASE="$(detect_base)" || { echo "未检测到安装。"; return 1; }
    _cf="$BASE/tgweb.conf"
    _host="$(get_conf TGWEB_HOST "$_cf")"
    _rport="$(get_conf RELAY_PORT "$_cf")"; [ -n "$_rport" ] || _rport=18547
    _aport="$(get_conf ADMIN_PORT "$_cf")";  [ -n "$_aport" ] || _aport=56462
    echo "安装目录: $BASE"
    echo "域名: ${_host:-未设置}"
    for _p in tproxy-server mtg cloudflared; do
        if pgrep -f "$BASE/bin/$_p" >/dev/null 2>&1; then _s="运行中"; else _s="未运行"; fi
        printf '  %-14s %s\n' "$_p" "$_s"
    done
    if command -v curl >/dev/null 2>&1; then
        if curl -sS -m 5 -o /dev/null "http://127.0.0.1:$_aport/healthz" 2>/dev/null; then
            echo "管理接口: 正常"
        else
            echo "管理接口: 无响应"
        fi
    fi
    _secret="$(get_conf SECRET "$_cf")"
    [ -n "$_secret" ] || _secret="$(sed -n '1p' "$BASE/var/secret.txt" 2>/dev/null | tr -d '\r\n ')"
    if [ -n "$_host" ] && [ -n "$_secret" ]; then
        echo "代理链接: https://t.me/webproxy?server=$_host&secret=$_secret"
    fi
}

# ---------- 日志 ----------
do_logs() {
    BASE="$(detect_base)" || { echo "未检测到安装。"; return 1; }
    if [ ! -f "$BASE/var/k.log" ]; then echo "暂无日志。"; return 1; fi
    tail -n 30 "$BASE/var/k.log"
    if confirm "实时跟踪日志？"; then
        tail -f "$BASE/var/k.log"
    fi
}

# ---------- 测试推送 ----------
do_test_push() {
    BASE="$(detect_base)" || { echo "未检测到安装。"; return 1; }
    mkdir -p "$BASE/var" 2>/dev/null
    : > "$BASE/var/.forcesend"
    echo "已触发推送：约 1 分钟内 bot 应收到「节点已上线」消息。"
    echo "可用「查看日志」确认 k.log 里出现 link sent to tg bot (manual)。"
}

# ---------- 重启 ----------
do_restart() {
    BASE="$(detect_base)" || { echo "未检测到安装。"; return 1; }
    for _p in cloudflared tproxy-server mtg; do
        pkill -f "$BASE/bin/$_p" 2>/dev/null
    done
    sleep 1
    TGWEB_BASE="$BASE" sh "$BASE/tgweb.sh"
    echo "已重启，保活脚本接管后续。"
}

# ---------- 卸载 ----------
do_uninstall() {
    BASE="$(detect_base)" || { echo "未检测到安装。"; return 1; }
    echo "将删除 $BASE（配置/日志/secret 全删），并移除保活任务。"
    printf '确认卸载？输入 YES 继续: '
    read -r _yn
    [ "$_yn" = "YES" ] || { echo "已取消。"; return 1; }
    if [ -f /etc/systemd/system/tgweb.timer ]; then
        systemctl disable --now tgweb.timer 2>/dev/null
        rm -f /etc/systemd/system/tgweb.service /etc/systemd/system/tgweb.timer
        systemctl daemon-reload 2>/dev/null
        echo "已移除 systemd timer。"
    fi
    if command -v crontab >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -vF "$BASE/tgweb.sh" | crontab -
        echo "已移除 cron 任务。"
    fi
    for _p in cloudflared tproxy-server mtg; do
        pkill -f "$BASE/bin/$_p" 2>/dev/null
    done
    case "$BASE" in ""|"/") echo "拒绝删除可疑路径。"; return 1 ;; esac
    rm -rf "$BASE"
    echo "已卸载。"
}

# ---------- 主菜单 ----------
while :; do
    echo ""
    echo "=============================="
    echo " tgweb 一键安装 / 管理"
    echo "=============================="
    if BASE="$(detect_base)"; then
        echo " 状态：已安装（$BASE）"
    else
        echo " 状态：未安装"
    fi
    echo "  1) 全新安装"
    echo "  2) 修改配置"
    echo "  3) 查看状态"
    echo "  4) 查看日志"
    echo "  5) 测试 TG 推送"
    echo "  6) 重启服务"
    echo "  7) 卸载"
    echo "  0) 退出"
    printf '请选择: '
    read -r _c
    case "$_c" in
        1) do_install ;;
        2) do_edit_conf ;;
        3) do_status ;;
        4) do_logs ;;
        5) do_test_push ;;
        6) do_restart ;;
        7) do_uninstall ;;
        0) exit 0 ;;
        *) echo "无效选择。" ;;
    esac
done
