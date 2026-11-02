#!/bin/bash
# -E 参数保留用/home/tanwubin下的.cache,避免去找/root下的.cache

export HF_HOME=/home/tanwubin/.cache/huggingface
export HF_HUB_CACHE=/home/tanwubin/.cache/huggingface/hub
sudo -E ./run-recipe.sh recipes/qwen3.8-flash-next-nvfp4-solo.yaml --solo \
  -e HF_HUB_OFFLINE=1 \
  -e HF_HOME=/home/tanwubin/.cache/huggingface \
  -e HF_HUB_CACHE=/home/tanwubin/.cache/huggingface/hub \
  -v /home/tanwubin/.cache/huggingface:/home/tanwubin/.cache/huggingface:ro \
  -v /home/tanwubin/projects/models:/home/tanwubin/projects/models:ro