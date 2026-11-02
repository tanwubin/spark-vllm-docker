# 同样只写到父目录（结尾不带 / 表示保留该目录名）
rsync -avP --partial \
  /home/tanwubin/projects/models/nvidia/Qwen3.8-Flash-Next-FP4-Local \
  tanwubin@192.168.100.10:/home/tanwubin/projects/models/nvidia/