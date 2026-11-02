set -e

HF_HUB=/home/tanwubin/.cache/huggingface/hub

# 本地真实模型目录（请确认路径存在）
SRC=/home/tanwubin/projects/models/nvidia/Qwen3.8-Flash-Next-FP4-Local

# 给 transformers 用的名字是 nvidia/Qwen3.8-Flash-Next-FP4-Local
CACHE=$HF_HUB/models--nvidia--Qwen3.8-Flash-Next-FP4-Local

# 0. 先确认源存在且非空，避免误删后才发现路径不对
if [ ! -d "$SRC" ] || [ -z "$(ls -A "$SRC")" ]; then
  echo "ERROR: SRC 不存在或为空: $SRC" >&2
  exit 1
fi
echo "== check src =="
ls -la "$SRC" | head

# 1. 清掉同名旧 cache，重建干净结构
rm -rf "$CACHE"
mkdir -p "$CACHE/refs" "$CACHE/snapshots/local"

# 2. refs/main = local（无换行）
printf 'local' > "$CACHE/refs/main"

# 3. 绝对路径建软链接（包含隐藏文件）
for f in "$SRC"/* "$SRC"/.[!.]*; do
  [ -e "$f" ] || continue
  ln -sfn "$f" "$CACHE/snapshots/local/$(basename "$f")"
done

# 4. 验证
echo "== snapshots =="
ls -l "$CACHE/snapshots/local/" | head -30
echo "== readlink config =="
readlink -f "$CACHE/snapshots/local/config.json"
echo "== refs =="
cat "$CACHE/refs/main"; echo

echo "== 可用名字 =="
echo "nvidia/Qwen3.8-Flash-Next-FP4-Local"