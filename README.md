# tgweb — Telegram 代理一键部署

在任意 x86_64 Linux 服务器（NAT 机、普通 VPS 都行）上一键部署 Telegram Web 代理。

链路：`Telegram → Cloudflare 443 → cloudflared → tproxy-server relay → mtg → Telegram DC`
NAT 机不需要放行任何入站端口（cloudflared 是向外连 Cloudflare 的）；
普通 VPS 也可以选直连模式，用公网 IP 直接提供服务。

## 快速开始

```sh
# 下载菜单脚本并运行（注意：不要用 curl | sh，交互式菜单需要终端）
curl -fsSLO https://raw.githubusercontent.com/saodisengyyds/tgweb/main/setup.sh
sh setup.sh
```

按菜单提示走：选 `1) 全新安装`，脚本会自动检测系统（Alpine / Debian / Ubuntu /
CentOS…）、提示安装缺失的依赖（curl 等）、从本仓库 Releases 下载安装包、
交互式填写配置，全程中文。

装好后同一个菜单可以：改配置、看状态、看日志、测试 TG 推送、重启、卸载。

## 仓库维护者必读（发布安装包）

1. 把 `tgweb-nat-linux-amd64.tar.gz` 上传到本仓库的 **Releases**（新建一个
   release，把 tarball 拖进附件，文件名保持不变）。
2. `setup.sh` 顶部的 `REPO` 已设为 `saodisengyyds/tgweb`（fork/改名后记得同步改），
   提交到仓库。

之后任何机器用上面的快速开始命令即可安装。更新版本时只需重新打包、
上传到新的 Release（文件名不变），已安装的机器用菜单 `7) 卸载` 后重装，
或直接覆盖 `tgweb.sh` 升级。

## 安装时要准备的东西

- 一台 x86_64 Linux 服务器，有 root（Alpine / Debian / Ubuntu / CentOS…）
- 二选一：
  - **Cloudflare Tunnel 模式**（推荐，NAT 机必选）：CF 后台 Zero Trust →
    Networks → Tunnels 建好 tunnel，拿到 token；再加一条 Public Hostname
    指向 `http://127.0.0.1:18547`
  - **直连模式**：机器有公网 IP，防火墙/安全组放行 relay 端口（默认 18547）
- （可选）Telegram bot 的 token 和 chat id：relay 每次启动自动把代理链接
  推送到 bot，30 分钟内重复启动不重复发

## 菜单功能

| 选项 | 说明 |
|---|---|
| 1) 全新安装 | 检测系统 → 装依赖 → 拉安装包 → 填配置 → 装保活 |
| 2) 修改配置 | 域名、token、端口、监听地址、bot 等，回车保持不变 |
| 3) 查看状态 | 各进程是否在跑、管理接口、代理链接 |
| 4) 查看日志 | `var/k.log` tail，可选实时跟踪 |
| 5) 测试 TG 推送 | 立即往 bot 推一条「节点已上线」（1 分钟内到达） |
| 6) 重启服务 | 杀掉重拉，保活接管后续 |
| 7) 卸载 | 删保活任务、进程和整个安装目录（需输入 YES 确认） |

## 常见问题

- **Alpine 上 cloudflared 起不来**：它是 glibc 编译的，菜单会自动装 `gcompat`。
- **bot 没收到推送**：检查 `tgweb.conf` 里 `BOT_TOKEN` / `CHAT_ID` 是否填了；
  用菜单 `5) 测试 TG 推送` 手动触发一次，看 `4) 查看日志` 里有没有
  `link sent to tg bot (manual)`。
- **换 secret**：菜单 `2) 修改配置` 里把 SECRET 填 `clear`，会自动生成新的并重启。
- **管理非默认目录的安装**：`TGWEB_BASE=/opt/tgweb sh setup.sh`。
- **ARM 机器**：安装包是 x86_64 的，ARM 跑不了。
