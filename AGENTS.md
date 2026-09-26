# 网络规则（中国网络代理）

当环境变量 `IS_CHINA` 的值为 `1`（中国网络环境）时，在使用 WebFetch 等工具抓取网页或下载文件**之前**，必须先检查 `IS_CHINA` 的值：若为 `1` 且链接命中下方「代理域名清单」中的域名，先在其前面添加前缀 `https://filetas.asfd.cn`，**然后再执行**抓取。严禁先
发起请求、失败后再补充代理前缀。

## 代理域名清单

| 域名 | 改写示例 |
| --- | --- |
| raw.githubusercontent.com | `https://filetas.asfd.cn/https://raw.githubusercontent.com/xxx` |

后续发现其他需要走代理的域名，直接在上表末尾追加一行即可（仅填域名与示例）。

若访问未在清单中的域名或链接失败（如超时、连接被重置），可先按上述方式将该域名加入清单并加前缀 `https://filetas.asfd.cn` 后，重新抓取尝试。

# 移植脚本编写约束（port-*.sh）

本仓库各移植脚本（`deveco-studio/`、`mimo-desktop/`、`workbuddy/` 等）统一遵循以下约束，新增脚本时同样适用：

## 1. set 模式（脚本顶部）

```bash
if [[ -n "$DEBUG" ]]; then
  set -eux
else
  set -euo pipefail
fi
```

- 支持 `DEBUG=1` 调试模式，打印每条执行的命令。

## 2. CDN 加速下载

下载函数统一走 CDN 加速：`IS_CHINA=1` 且 URL 命中代理域名清单时使用 `<CDN>/<完整原始 URL>` 形式下载，失败自动回退直连。

- 默认 CDN：`https://fastfile.asfd.cn/`，可通过环境变量 `CDN=<url>` 覆盖
- `CDN` 归一化：无论传入是否带 `/` 结尾，统一归一为末尾恰好一个 `/`
- 仅对 CDN 适用域名生效（如 `github.com`、`raw.githubusercontent.com`、`objects.githubusercontent.com` 等 GitHub 系域名）；npm registry 等其他域名不走 CDN
- 仅 `IS_CHINA=1` 时启用，否则行为与直连一致

## 3. 必须提供帮助信息

- 脚本必须支持 `-h` / `--help` 查看帮助信息（独立 `usage()` 函数）
- 帮助内容包含：脚本简介、用法示例、选项说明、环境变量、依赖
- 未知选项 / 参数报错时也应先打印帮助到 stderr 再退出

