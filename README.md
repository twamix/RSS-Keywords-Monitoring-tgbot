这是一个监控RSS关键字，并将含有关键字的内容推送至群组的tgbot

你只需要将脚本下载下来，修改里面的群组ID、管理员ID、机器人token，修改完成后上传至你的服务器当中，给予权限运行即可！

使用以下命令管理服务：
- 查看状态：supervisorctl status tgbot
- 重启服务：supervisorctl restart tgbot
- 停止服务：supervisorctl stop tgbot
- 查看日志：tail -f /var/log/tgbot/err.log
