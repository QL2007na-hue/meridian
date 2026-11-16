# legacy/ — 作者个人服务器的历史补丁（不通用，仅供参考）

这里曾经放过两个脚本，用于把 Meridian 注入到**作者自己那台服务器**的门户与 nginx 配置里：

- `patch_nginx.py` —— 在已有的 nginx server 块里插入 `/meridian/` location（依赖该站点的 `/admin/` 锚点）
- `patch_portal.py` —— 在作者的服务器门户首页追加第 15 张卡片

开源版不再包含它们：**改别人的 nginx 配置和门户首页不应该是一个安装脚本的职责**。
正确的做法是用 `deploy/nginx-meridian.conf.example` 建独立站点，门户则按需自己加一个链接。

保留这段说明是为了让后来看到历史提交的人知道这两个文件为什么消失。
