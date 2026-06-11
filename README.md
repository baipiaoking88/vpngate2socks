# vpngate2socks

将 VPN Gate 公共节点转换为本地 SOCKS5 代理，突破机房 IP 限制。

基于 Docker + OpenVPN + microsocks，单容器运行，零宿主机污染。

## 快速开始

```bash
git clone https://github.com/baipiaoking88/vpngate2socks.git
cd vpngate2socks

# 启动（自动选最快节点）
docker compose up -d

# 指定国家
COUNTRY=JP docker compose up -d

curl --proxy socks5://127.0.0.1:1080 https://ipapi.co/json/
```

## 配置

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `COUNTRY` | (所有) | 国家代码过滤，见 Country_code.txt |
| `IP_TYPE` | (不限制) | IP 类型优先: `residential` / `proxy` / `hosting` |
| `PROXY_PORT` | 1080 | SOCKS5 代理端口 |
| `MAX_NODES` | 100 | 每次拉取的最大节点数 |
| `CHECK_INTERVAL` | 60 | 健康检查间隔（秒） |

## 工作原理

```
容器启动 → 拉取 VPN Gate API(最多 MAX_NODES 个)
         → 按 COUNTRY 过滤
              → 连续 3 次无匹配节点 → 自动放弃过滤，使用全部节点
         → 按 IP_TYPE 优先排序(将匹配类型节点提到最前)
         → Ping 测速 top 20 选最快
         → 启动 microsocks SOCKS5 代理
         → 按 Ping 排序依次尝试 OpenVPN 连接
         → 连接成功后每 CHECK_INTERVAL 秒检查:
              • VPN 进程存活
              • 出口 IP 国家是否匹配
              • microsocks 是否运行
         → 检测到异常自动切换下一节点
         → 全部节点耗尽后重新拉取
```

## 验证出口 IP

```bash
curl --proxy socks5://127.0.0.1:1080 http://ip-api.com/json
```

## 其他命令

```bash
docker compose logs -f      # 查看实时日志
docker compose restart       # 手动重启
docker compose down          # 停止
docker compose pull          # 更新镜像
```
