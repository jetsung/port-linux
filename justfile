# port-linux 统一构建入口 —— 封装 port-linux-base 镜像与各项目 port.sh 的移植构建
set shell := ["bash", "-cu"]

# 镜像名与各项目目录
image_name := "port-linux-base"

# 默认：列出全部配方
default:
    @just --list

# 构建基础镜像 port-linux-base（debian:13 + 全套前置依赖 + 中国镜像源）
[group('docker')]
image:
    docker build -t {{ image_name }} .

# 构建非中国网络环境的基础镜像
[group('docker')]
image-global:
    docker build --build-arg IS_CHINA=0 -t {{ image_name }} .

# 通用移植：在 <dir> 项目目录下执行 ./port.sh（参数透传，如 just port workbuddy -p deb）
port dir *args:
    cd {{ dir }} && docker run --rm -v "$PWD":/src {{ image_name }} ./port.sh {{ args }}

# 交互式调试：在 <dir> 项目目录下进入容器
shell dir:
    cd {{ dir }} && docker run --rm -it -v "$PWD":/src {{ image_name }} bash

# 移植 workbuddy（腾讯 WorkBuddy，macOS zip → deb/rpm）
[group('soft')]
workbuddy *args:
    @just port workbuddy {{ args }}

# 移植 mimo-desktop（Xiaomi MiMo，Linux deb + Windows exe → deb/rpm）
[group('soft')]
mimo *args:
    @just port mimo-desktop {{ args }}

# 移植 deepseek-harness（DeepSeek 桌面智能体，macOS DMG → deb/rpm）
[group('soft')]
dsh-desktop *args:
    @just port deepseek-harness {{ args }}

# 移植 codearts（华为云 CodeArts，macOS zip → deb/rpm）
[group('soft')]
codearts *args:
    @just port codearts {{ args }}

# 移植 deveco-studio（DevEco Studio，Mac DMG + IDEA Linux 组件 → tar.gz）
[group('soft')]
deveco-studio *args:
    @just port deveco-studio {{ args }}

# 移植 open-design（Open Design，Windows x64 NSIS exe → deb/rpm）
[group('soft')]
open-design *args:
    @just port open-design {{ args }}

# 清理指定项目目录下的 build/ 产物
clean dir:
    rm -rf {{ dir }}/build
