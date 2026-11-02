# Docker 镜像操作指南（DGX Spark / spark-vllm-docker）

本文件汇总在本仓库里准备、校验、跨机分发 vLLM Docker 镜像的各种方案与操作步骤，
作为 [README.md](README.md) 与 [docs/AGENT_RUNBOOK.md](docs/AGENT_RUNBOOK.md) 的实操补充。
所有命令在仓库根目录执行，且假定当前用户已在 `docker` 组（无需 `sudo`）。

## Table of Contents

- [1. 先理解几个概念](#1-先理解几个概念)
- [2. 镜像命名与 recipe 的关系](#2-镜像命名与-recipe-的关系)
- [3. containerd 镜像存储的坑（务必读）](#3-containerd-镜像存储的坑务必读)
- [4. 前置准备](#4-前置准备)
- [5. 方案总览](#5-方案总览)
- [6. 方案 A：拉取官方预构建镜像（build-and-copy.sh）](#6-方案-a拉取官方预构建镜像build-and-copysh)
- [7. 方案 B：跨机拷贝（推荐 build-and-copy.sh -c）](#7-方案-b跨机拷贝推荐-build-and-copysh--c)
- [8. 方案 C：手动 docker save | ssh docker load](#8-方案-c手动-docker-save--ssh-docker-load)
- [9. 方案 D：目标机直接 docker pull](#9-方案-d目标机直接-docker-pull)
- [10. 核对是否成功](#10-核对是否成功)
- [11. 清理悬空镜像](#11-清理悬空镜像)
- [12. 命令速查表](#12-命令速查表)
- [13. 常见问题（FAQ）](#13-常见问题faq)

## 1. 先理解几个概念

- **`docker tag` 只是“贴别名”，不复制数据。**
  `docker tag SRC TARGET` 让 `TARGET` 与 `SRC` 指向**同一份镜像（同一 image ID）**，
  不重新构建、不占额外空间。旧标签失去名字后会变成“悬空（dangling）”镜像，需 `docker image prune` 清理。

- **`docker tag` 不会去拉最新。** 它只给“本地已有的那份镜像”换名字。
  想要真正更新到 Docker Hub 上的最新版，必须先 `docker pull`。

- **`docker pull` + `docker tag` = 官方镜像的标准落地方式。**
  本仓库的 `build-and-copy.sh --exp-b12x` 内部就是自动做这两步（见 `build-and-copy.sh` 的 prebuilt 分支）。
  因此“更新官方镜像”通常只需跑 `build-and-copy.sh`，不必手动 `docker tag`。

- **`docker save` / `docker load` 是离线搬运方式。**
  `docker save` 把镜像导出成 tar，`docker load` 在目标机导入，常配合 `ssh` 做跨机拷贝。

## 2. 镜像命名与 recipe 的关系

recipe 的 YAML 里有一个 `container:` 字段，决定 `run-recipe.sh` / `launch-cluster.sh` 实际去 `docker run` 哪个标签：

| recipe 类型 | `container:` 取值 | 由哪个 profile 产生 |
| :--- | :--- | :--- |
| 常规（regular）镜像 | `vllm-node` | `./build-and-copy.sh`（默认） |
| B12X 实验镜像（本仓库 Qwen3.8 Flash Next 等） | `vllm-node-b12x` | `./build-and-copy.sh --exp-b12x` |

> 例：`recipes/qwen3.8-flash-next-nvfp4-solo.yaml` 第 10 行 `container: vllm-node-b12x`，
> 因此该 recipe 启动时查找的就是 **`vllm-node-b12x`** 这个标签，而不是 `eugr/spark-vllm-b12x`。
> 跨机拷贝/落地后，务必保证目标机上 `vllm-node-b12x` 指向正确的镜像。

官方在 Docker Hub 上的预构建镜像名与本仓库使用的本地标签对应关系：

| Docker Hub 预构建镜像 | 落地后的本地标签（默认） | 触发命令 |
| :--- | :--- | :--- |
| `eugr/spark-vllm:latest` | `vllm-node` | `./build-and-copy.sh` |
| `eugr/spark-vllm-b12x:latest` | `vllm-node-b12x` | `./build-and-copy.sh --exp-b12x` |

## 3. containerd 镜像存储的坑（务必读）

DGX Spark 上的 Docker 若启用了 **containerd 镜像存储**，会有两个反直觉现象，直接影响你怎么判断“拷贝是否成功”：

1. **跨机 `save`/`load` 后 image ID 会变，这不代表拷错。**
   经典 Docker 的 ID 是镜像 config 的哈希；containerd 存储的 ID 可能标识 manifest/index，
   `save`→`load` 过程中 ID 及 `RepoDigests` 都可能变化或消失。
   **判断是否同一镜像要看“内容指纹”（见第 10 节），不要只看 `docker images` 的 ID 列。**

2. **`docker save` / `docker load` 可能“报成功却只传了元数据”。**
   某些带 containerd 存储的 Docker 版本，`save` 和 `load` 都返回成功，
   但实际没搬运真正的层（layer）数据（参见 Moby issue #49473）。
   所以“`Loaded image: ...`”这一行**不足以证明成功**——必须看 CONTENT SIZE 是否变到位、
   并用 `docker/image_archive.py` 校验导出 tar。仓库的 `build-and-copy.sh` 已内置这两道校验。

> 用 `docker images` 时留意表头的 `CONTENT SIZE`（真实内容大小）而非仅 `DISK USAGE`：
> 若目标机 `vllm-node-b12x` 的 CONTENT SIZE 仍是旧的小值，说明层数据没真正传过去。

## 4. 前置准备

跨机拷贝依赖 **SSH 免密**（脚本底层是 `ssh <user>@<host> "docker load"`）。
新配对的节点常因“本机无私钥/未建互信”导致 `Permission denied (publickey,password)`。先打通：

```bash
# 4.1 本机若无 SSH 私钥，先生成一个（已有则跳过；-N "" 表示不设口令）
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# 4.2 把公钥装到对端（会提示输入对端登录密码，仅此一次）
ssh-copy-id -i ~/.ssh/id_ed25519.pub <user>@<PEER_IP>

# 若对端没有 ssh-copy-id，用这条等效命令：
cat ~/.ssh/id_ed25519.pub | ssh <user>@<PEER_IP> \
  "install -d -m 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

# 4.3 验证：免密成功 + 对端 docker 可用 + 对端用户在 docker 组
ssh -o BatchMode=yes <user>@<PEER_IP> 'echo OK && docker --version && id -nG'
```

- 第 4.3 步应看到 `OK`、`Docker version ...`，且 `id -nG` 含 `docker`。
- **对端用户必须在 `docker` 组**：脚本拷贝走的是裸 `docker load`（无 sudo）。不在组内请用方案 C 的 sudo 兜底，或在目标机把用户加入 docker 组后重新登录。

> 快速确认网络与镜像现状（本机侧）：
>
> ```bash
> ping -c 2 -W 2 <PEER_IP>          # 直连是否可达（IB 网口最快）
> docker images | grep -E 'vllm|spark|b12x'   # 本机有哪些镜像
> ```

## 5. 方案总览

| 方案 | 适用场景 | 是否需 SSH | 是否需目标机联网 | 校验强度 |
| :--- | :--- | :--- | :--- | :--- |
| A. `build-and-copy.sh` 拉官方预构建 | 想更新到 Docker Hub 最新镜像 | 否（仅本机） | 是（本机） | 高 |
| B. `build-and-copy.sh ... -c` 跨机拷贝 | 把本机镜像推到其它节点 | 是 | 否 | **最高（内置去重+完整性校验）** |
| C. `docker save \| ssh docker load` | 脚本不可用/极简一行流 | 是 | 否 | 低（自行校验） |
| D. 目标机直接 `docker pull` | 目标机能联网、最省事 | 是（或本机手敲） | 是（目标机） | 中 |

**优先用 B**：`build-and-copy.sh` 的拷贝流程会
（1）先比对本地/远端镜像内容指纹做去重、（2）`docker save` 后用 `docker/image_archive.py` 校验 tar 完整性、
（3）`docker load` 后再次比对指纹，三道防线避免“假成功”。

## 6. 方案 A：拉取官方预构建镜像（build-and-copy.sh）

把 Docker Hub 上的官方测试镜像拉到本机并打上 recipe 需要的本地标签。`--exp-b12x` 会执行
`docker pull eugr/spark-vllm-b12x:latest` 然后 `docker tag ... vllm-node-b12x`。

```bash
cd ~/projects/spark-vllm-docker

# B12X 镜像（Qwen3.8 Flash Next / DeepSeek Vision 等用）
./build-and-copy.sh --exp-b12x

# 常规镜像（Qwen3.8-27B 等用）
./build-and-copy.sh
```

要点：

- 不带本地构建类 flag 时，它只做 **pull + tag**，不会本地编译，快且安全。
- 上游有新版镜像时，重跑同一条命令即可“更新 + 重打标签”，无需再手动 `docker tag`。
- 从源码编译实验分支用 `--exp-b12x --rebuild-vllm`（此时不再 pull 预构建镜像，改走 `docker build`）。
- `--use-wheels` 与 `--exp-b12x` **互斥**（实验版不发布 vLLM wheels）。

落地后核对（应看到两个标签同一 image ID）：

```bash
docker images | grep -E 'spark-vllm-b12x|vllm-node-b12x'
```

## 7. 方案 B：跨机拷贝（推荐 build-and-copy.sh -c）

把本机已有镜像推到其它 Spark 节点。**先完成第 4 节 SSH 免密**。示例：把 `vllm-node-b12x` 拷到 `192.168.100.10`。

```bash
cd ~/projects/spark-vllm-docker

# 7.1 确认本机磁盘足够：脚本会把镜像存到 $TMPDIR 的临时 tar（B12X 约需 >18GB 空闲）
df -h "${TMPDIR:-/tmp}"
# /tmp 若是小分区或 tmpfs，先把临时目录指到大盘，避免挤爆内存盘：
mkdir -p ~/tmp && export TMPDIR=~/tmp

# 7.2 执行拷贝：-t 指定要拷的标签，-c 指定目标机，--no-build 跳过任何 pull/build
./build-and-copy.sh --no-build -t vllm-node-b12x -c 192.168.100.10
```

成功标志（脚本会逐条打印）：

```text
Saving image locally to /tmp/... 
Loading image into tanwubin@192.168.100.10...
Copy to 192.168.100.10 completed in 00:00:xx
Copy complete.
```

若目标机已有同内容镜像，会打印 `... already up to date ... skipping`（无需重传）。

要点：

- `--no-build` **必须**配合 `-c`（脚本会强制校验），且它**不会**去 pull，保证推的就是本机当前这份。
- `-t` 指定要拷贝的标签；不写默认是 `vllm-node`，拷 B12X 必须显式 `-t vllm-node-b12x`。
- 对端登录名与本机不同时加 `-u <对端用户>`：`./build-and-copy.sh --no-build -t vllm-node-b12x -c 192.168.100.10 -u <user>`。
- 多机并发拷贝：`-c host1,host2 --copy-parallel`；省略 `-c` 的地址则用 `.env` 里的 `COPY_HOSTS` 或自动发现。
- 想“更新到最新再拷”，去掉 `--no-build` 用 `./build-and-copy.sh --exp-b12x -c 192.168.100.10`（会先 pull 官方最新）。

## 8. 方案 C：手动 docker save | ssh docker load

不想用脚本时的极简一行流（README 官方写法）。**先完成第 4 节 SSH 免密**。

```bash
# 8.1 拷本机镜像到对端（走 SSH；192.168.100.x 是 IB 直连，很快）
docker save vllm-node-b12x:latest | ssh <user>@<PEER_IP> 'docker load'

# 8.2 对端核对（务必做第 10 节的内容指纹比对，别只看 Loaded 那行）
ssh <user>@<PEER_IP> 'docker images | grep vllm-node-b12x'
```

【对端需要 sudo 时的兜底】（`docker load` 报 permission denied）：

```bash
docker save vllm-node-b12x:latest | ssh <user>@<PEER_IP> 'sudo docker load'
```

> 手动方式**不带**脚本的 tar 完整性校验与内容指纹校验。为防“只传元数据的假成功”，
> 可在本机先校验导出 tar，再决定是否信任这次传输：
>
> ```bash
> docker save -o /tmp/img.tar vllm-node-b12x:latest
> python3 docker/image_archive.py /tmp/img.tar && echo "archive OK"   # 校验 config+层是否齐全
> cat /tmp/img.tar | ssh <user>@<PEER_IP> 'docker load' && rm -f /tmp/img.tar
> ```

## 9. 方案 D：目标机直接 docker pull

若目标机能访问 Docker Hub，最省事、无需拷贝。在**目标机**上执行：

```bash
docker pull eugr/spark-vllm-b12x:latest && \
docker tag  eugr/spark-vllm-b12x:latest vllm-node-b12x:latest
```

从本机一条 SSH 命令代跑：

```bash
ssh <user>@<PEER_IP> \
  'docker pull eugr/spark-vllm-b12x:latest && docker tag eugr/spark-vllm-b12x:latest vllm-node-b12x:latest && docker images | grep -E "vllm-node-b12x|spark-vllm-b12x"'
```

要点：

- `docker tag` 是本地、秒级、不占额外空间的操作。
- 只有走 pull 这条路时才需要**额外补 `docker tag`**（把官方名映射到 recipe 用的 `vllm-node-b12x`）；
  方案 B/C 因为拷的就是本机 `vllm-node-b12x:latest`，标签会随镜像一起带过去。
- 拉到的镜像若与本机是同一官方版本，则内容指纹一致（见第 10 节）。

## 10. 核对是否成功

跨机拷贝“`Loaded image: ...`”不足以证明成功（见第 3 节）。用以下三层核对：

**① 快速看 CONTENT SIZE（粗筛）**

```bash
# 本机与目标机分别执行；两边 CONTENT SIZE 应接近（B12X 约 18.2GB 量级）
docker images | grep -E 'vllm-node-b12x|spark-vllm-b12x'
```

**② 用仓库自带工具比对“内容指纹”（权威判定）**

`docker/image_identity.py` 从 `docker image inspect` 结果中提取
platform + 未压缩层摘要 + runtime config，算出一个**与 ID/RepoDigests 无关的等价性指纹**。
这正是 `build-and-copy.sh` 拷贝去重所用的判定，也是 containerd 存储下比 ID 更可靠的方法。

```bash
# 在“源机”上，记下指纹（记为 F_src）
cd ~/projects/spark-vllm-docker
docker image inspect vllm-node-b12x:latest | python3 docker/image_identity.py

# 在“目标机”上，算同一标签的指纹（记为 F_dst）
cd ~/projects/spark-vllm-docker
docker image inspect vllm-node-b12x:latest | python3 docker/image_identity.py
```

- **F_src == F_dst → 内容逐字节等价，拷贝成功**，可放心用 recipe 启动。
- 不一致 → 传输被截断/损坏，重跑方案 B 或 C。
- 参考值（本仓库当前 B12X 镜像 `vllm-node-b12x` / `e919f534c4d9`）：
  `sha256:e33bf793079a66cd2738d6a2acff0ff0bbdeef67469f5d965281f66e193569ba`
  （仅作参照，以你实际算出的、两边一致的指纹为准。）

一条命令直接从本机远程比对目标机（需已 SSH 免密，且目标机也有该仓库）：

```bash
SRC=$(docker image inspect vllm-node-b12x:latest | python3 docker/image_identity.py)
DST=$(ssh <user>@<PEER_IP> 'cd ~/projects/spark-vllm-docker && docker image inspect vllm-node-b12x:latest | python3 docker/image_identity.py')
echo "src=$SRC"; echo "dst=$DST"; [ "$SRC" = "$DST" ] && echo "MATCH" || echo "MISMATCH"
```

**③ 端到端确认（可选，最硬的证据）**

在目标机用 recipe 起服务，能正常加载并响应即证明镜像可用：

```bash
# 目标机上，若之前是慢启动会重新编译，首次较慢属正常
./run-recipe.sh recipes/qwen3.8-flash-next-nvfp4-solo.yaml --solo
# 另开终端验证
curl http://127.0.0.1:8000/v1/models
```

> 关于“ID 不一样”：源机与目标机的 `vllm-node-b12x` 若 ID 不同但指纹相同，**这是正确的**（见第 3 节）。

## 11. 清理悬空镜像

`docker tag` 改名、或 `docker load` 覆盖同名标签后，旧的、无标签引用的镜像会成为“悬空（dangling）”镜像。**确认新镜像跑通后**再清理，别在验证成功前删，以免需要回退：

```bash
docker images -f dangling=true          # 先看看要删什么
docker image prune                       # 只删无标签悬空镜像（交互式确认）
```

> 注意：`build-and-copy.sh --cleanup` 清的是 **wheel 缓存与构建溯源标记**，不是 docker 悬空镜像；两者别混。
> 删除正在被容器使用的镜像会失败或被拒，属正常保护。

## 12. 命令速查表

| 目的 | 命令 |
| :--- | :--- |
| 拉官方 B12X 并打标签 | `./build-and-copy.sh --exp-b12x` |
| 拉官方常规并打标签 | `./build-and-copy.sh` |
| 从源码编译 B12X | `./build-and-copy.sh --exp-b12x --rebuild-vllm` |
| 跨机拷贝本机 B12X 到某节点 | `./build-and-copy.sh --no-build -t vllm-node-b12x -c <PEER_IP>` |
| 多机并发拷贝 | `./build-and-copy.sh --no-build -t vllm-node-b12x -c h1,h2 --copy-parallel` |
| 指定对端登录名 | 追加 `-u <对端用户>` |
| 手动一行流拷贝 | `docker save vllm-node-b12x:latest \| ssh <user>@<PEER_IP> 'docker load'` |
| 校验导出 tar 完整性 | `docker save -o /tmp/i.tar vllm-node-b12x:latest && python3 docker/image_archive.py /tmp/i.tar` |
| 算内容指纹（去重/等价判定） | `docker image inspect vllm-node-b12x:latest \| python3 docker/image_identity.py` |
| 目标机直接拉取+补标签 | `docker pull eugr/spark-vllm-b12x:latest && docker tag eugr/spark-vllm-b12x:latest vllm-node-b12x:latest` |
| 重打标签（别名） | `docker tag eugr/spark-vllm-b12x:latest vllm-node-b12x:latest` |
| 列出 vllm 相关镜像 | `docker images \| grep -E 'vllm\|spark\|b12x'` |
| 清理悬空镜像 | `docker image prune` |

## 13. 常见问题（FAQ）

- **Q：`Permission denied (publickey,password)`？**
  A：本机与对端没建过 SSH 互信。按第 4 节生成密钥并 `ssh-copy-id`。`build-and-copy.sh` 用 `docker`（无需 sudo），但 SSH 免密是跨机拷贝的前置。

- **Q：目标机 `docker load` 报 permission denied？**
  A：对端用户不在 `docker` 组。用方案 C 的 `sudo docker load` 兜底，或在目标机把用户加入 docker 组并重新登录。

- **Q：拷贝后两边 ID 不一样，是不是失败？**
  A：多半不是。containerd 存储下 `save/load` 会改变 image ID（见第 3 节）。用第 10 节的**内容指纹**判定：相同即成功。

- **Q：`Loaded image: ...` 出现，但 recipe 起服务又报缺层/旧版行为？**
  A：可能命中“只传元数据”的假成功（第 3 节）。看 CONTENT SIZE 是否变到位，并用 `docker/image_archive.py` 校验导出 tar；优先改用方案 B 的脚本拷贝。

- **Q：`docker tag` 后旧镜像会自己消失吗？**
  A：不会。它只是失去标签变悬空，确认新镜像跑通后用 `docker image prune` 清理（第 11 节）。

- **Q：脚本拷贝会不会占用很多磁盘？**
  A：会在 `$TMPDIR` 落一个与镜像同量级的临时 tar（B12X 约 18GB）。跑前 `df -h` 确认空间，必要时 `export TMPDIR=~/tmp` 指到大盘（第 7 节）。

- **Q：什么时候才需要 `build-and-copy.sh`，什么时候手动就够？**
  A：想“更新到官方最新”或做集群分发用脚本（它 = pull+tag(+copy)，并带完整性校验）；只是把本机现成镜像推到某台机器，手动 `docker save|ssh docker load` 即可，但记得自行做第 10 节校验。



