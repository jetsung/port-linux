# port-linux 统一基础构建环境
#
# 合并各移植项目（codearts / deepseek-harness / deveco-studio / mimo-desktop /
# workbuddy / open-design）在 debian:13 容器内的前置依赖，并预配置中国镜像源：
#   - apt   → 清华 TUNA
#   - npm   → npmmirror（同时导出 NPM_CONFIG_REGISTRY 供各脚本继承）
#   - pip   → 清华 TUNA PyPI
#   - bun   → npmmirror（bunfig.toml）
#
# 构建：
#   docker build -t port-linux-base .
#   # 非中国网络环境：docker build --build-arg IS_CHINA=0 -t port-linux-base .
#
# 使用（在 port.sh 脚本及移植包所在路径下执行）：
#   docker build -t port-linux-base .
#   cd <项目目录>   # 例如 workbuddy/，目录内含 port.sh 与移植包
#   docker run --rm -it -v "$PWD":/src port-linux-base bash
#   docker run --rm -v "$PWD":/src port-linux-base ./port.sh -p deb

FROM debian:13

WORKDIR /src

ARG IS_CHINA=1
ENV IS_CHINA=${IS_CHINA}

RUN if [ "$IS_CHINA" = "1" ]; then \
        sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget \
        unzip 7zip tar xz-utils binutils libarchive-tools \
        file jq git procps \
        nodejs npm python3 python3-pip \
        build-essential dpkg-dev \
        rpm cpio && \
    rm -rf /var/lib/apt/lists/*
# 依赖说明（对应各移植项目）：
#   ca-certificates curl wget        下载源包（全部项目）
#   unzip 7zip tar xz-utils          解 macOS zip / dmg / tar 源（workbuddy、deepseek-harness、mimo）
#   libarchive-tools                 提供 bsdtar（deveco-studio CLI zip 解压）
#   binutils                         ar + xz 降级打 deb（deepseek-harness、mimo）
#   file                             识别 Mach-O / ELF，清理 darwin 原生模块（workbuddy）
#   jq                               JSON 处理（README 汇总依赖）
#   nodejs npm                       npx asar 解包 / npm 包下载（全部项目）
#   python3 python3-pip              脚本内 JSON / plist 处理（deepseek-harness、codearts）
#   build-essential                  编译 node-pty / better-sqlite3 等 native 模块（deepseek-harness、open-design）
#   7zip / binutils(strings) / file  open-design：解 NSIS 双层 payload、从 PE 探测 Electron 版本、判 PE 残留
#   dpkg-deb（dpkg-dev）             解 deb 基底与打 deb 产物（workbuddy、mimo）
#   rpm cpio                         rpm2cpio 解 rpm 基底；容器内无法打 rpm（rpmbuild 缺失，脚本自动跳过）

# ---------- npm：npmmirror（系统级） ----------
RUN npm config set registry https://registry.npmmirror.com
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com

# ---------- pip：清华 TUNA（系统级） ----------
RUN pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple || true
ENV PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# ---------- bun：npmmirror（bunfig.toml） + 通过 npm 安装 bun ----------
RUN if [ "$IS_CHINA" = "1" ]; then \
        npm install -g bun; \
    else \
        curl -fsSL https://bun.sh/install | bash && \
        ln -sf /root/.bun/bin/bun /usr/local/bin/bun; \
    fi && \
    mkdir -p /root/.bun && \
    printf '[install]\nregistry = "https://registry.npmmirror.com/"\n' > /root/.bunfig.toml

CMD ["/bin/bash"]
