mpv script to precache the next entry in your playlist if it is a network source by downloading it to a temp file ahead of time. It will delete the directory on exit.
--
control with auto profiles:
```
[ytdl_pl]
profile-cond=...
script-opts=enable_ytdl_preload=no,ytdl_preload_keep_faults=no,ytdl_preload_ytdl_opt1=-N 5
```
