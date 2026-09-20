#!/bin/bash
# -E 参数保留用/home/tanwubin下的.cache,避免去找/root下的.cache

sudo -E ./run-recipe.sh recipes/qwen3.8-flash-next-nvfp4-solo.yaml --solo   -e HF_HUB_OFFLINE=1   -v /home/tanwubin/projects/models:/home/tanwubin/projects/models:ro