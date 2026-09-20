set -e

HF_HUB=/home/tanwubin/.cache/huggingface/hub

# 改这里为你本地真实路径
# SRC=/home/tanwubin/projects/models/nv-community/Qwen3.8-Flash-Next-NVFP4
SRC=/home/tanwubin/projects/models/local-inference-lab/Qwen3.8-Flash-Next-NVFP4
CACHE=$HF_HUB/models--local-inference-lab--Qwen3.8-Flash-Next-NVFP4

# 0. 确认源存在且非空
echo "== check src =="
ls -la "$SRC" | head

# 1. 清掉旧 cache，重建干净结构
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