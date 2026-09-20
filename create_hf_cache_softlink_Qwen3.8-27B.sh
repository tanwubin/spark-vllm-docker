set -e

HF_HUB=/home/tanwubin/.cache/huggingface/hub

MAIN_SRC=/home/tanwubin/projects/models/nv-community/Qwen3.8-Flash-Next-NVFP4
MAIN_CACHE=$HF_HUB/models--nvidia--Qwen3.8-27B-NVFP4

DRAFT_SRC=/home/tanwubin/projects/models/z-lab/Qwen3.8-27B-DFlash2
DRAFT_CACHE=$HF_HUB/models--z-lab--Qwen3.8-27B-DFlash2

# 0. 先确认源目录存在且非空，否则 * 不会展开
echo "== check main src =="
ls -la "$MAIN_SRC" | head
echo "== check draft src =="
ls -la "$DRAFT_SRC" | head

# 1. 删除旧 cache 目录，重建干净结构
rm -rf "$MAIN_CACHE" "$DRAFT_CACHE"
mkdir -p "$MAIN_CACHE/refs"  "$MAIN_CACHE/snapshots/local"
mkdir -p "$DRAFT_CACHE/refs" "$DRAFT_CACHE/snapshots/local"

# 2. 写 refs/main 为 local（无换行）
printf 'local' > "$MAIN_CACHE/refs/main"
printf 'local' > "$DRAFT_CACHE/refs/main"

# 3. 用绝对路径建软链接：主模型
for f in "$MAIN_SRC"/* "$MAIN_SRC"/.[!.]*; do
  [ -e "$f" ] || continue
  ln -sfn "$f" "$MAIN_CACHE/snapshots/local/$(basename "$f")"
done

# 4. 用绝对路径建软链接：draft 模型
for f in "$DRAFT_SRC"/* "$DRAFT_SRC"/.[!.]*; do
  [ -e "$f" ] || continue
  ln -sfn "$f" "$DRAFT_CACHE/snapshots/local/$(basename "$f")"
done

# 5. 验证
echo "== main snapshots =="
ls -l "$MAIN_CACHE/snapshots/local/" | head -30
echo "== draft snapshots =="
ls -l "$DRAFT_CACHE/snapshots/local/" | head -30

echo "== readlink main config =="
readlink -f "$MAIN_CACHE/snapshots/local/config.json"
echo "== readlink draft config =="
readlink -f "$DRAFT_CACHE/snapshots/local/config.json"

echo "== refs main =="
cat "$MAIN_CACHE/refs/main"; echo
cat "$DRAFT_CACHE/refs/main"; echo