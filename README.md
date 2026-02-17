mpv script to precache the next entry in your playlist if it is a network source by downloading it to a temp file ahead of time. It will delete the directory on exit. Old gist: https://gist.github.com/bitingsock/17d90e3deeb35b5f75e55adb19098f58
--
key to disable with auto profiles:
```
[ytdl_pl]
profile-cond=...
script-opts=enable_ytdl_preload=no
```
