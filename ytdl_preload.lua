----------------------
-- #example ytdl_preload.conf
-- # make sure lines do not have trailing whitespace
-- # ytdl_opt has no sanity check and should be formatted exactly how it would appear in yt-dlp CLI, they are split into a key/value pair on whitespace
-- # at least on Windows, do not escape '\' in temp, just us a single one for each divider

-- temp=C:\tmp\ytdl
-- keep_faults=no
-- ytdl_opt1=-N 5
-- ytdl_opt2=--sub-langs en.*
-- ytdl_opt#=etc
----------------------
local pathSep = package.config:sub(1, 1)
local platform_is_windows = (pathSep == "\\")
local nextIndex
local caught = true
local ytdl = "yt-dlp"
local utils = require("mp.utils")
local options = require("mp.options")
local opts = {
	temp = platform_is_windows and os.getenv("TEMP") or "/tmp",
	format = mp.get_property("ytdl-format"),
	keep_faults = tostring(mp.get_opt(mp.get_script_name().."_keep_faults") or "false")
}
local toggleFaults = ""
for i = 1,99 do
	opts["ytdl_opt"..i]=""
end
if opts.temp == nil then
	opts.temp = "C:\\temp\\ytdl"
else 
	opts.temp = opts.temp..pathSep.."ytdl"
end

options.read_options(opts, mp.get_script_name())

local additionalOpts = {}
for k, v in pairs(opts) do
	if k:find("ytdl_opt%d+") and v ~= "" then
		additionalOpts[k] = v
	end
end
local cachePath = opts.temp

local restrictFilenames = "--no-windows-filenames"
local chapter_list = {}
local json = ""
local filesToDelete = {}

local function useNewLoadfile()
	for _, c in pairs(mp.get_property_native("command-list")) do
		if c["name"] == "loadfile" then
			for _, a in pairs(c["args"]) do
				if a["name"] == "index" then
					return true
				end
			end
		end
	end
end

--from ytdl_hook
local function time_to_secs(time_string)
	local ret
	local a, b, c = time_string:match("(%d+):(%d%d?):(%d%d)")
	if a ~= nil then
		ret = (a * 3600 + b * 60 + c)
	else
		a, b = time_string:match("(%d%d?):(%d%d)")
		if a ~= nil then
			ret = (a * 60 + b)
		end
	end
	return ret
end
local function extract_chapters(data, video_length)
	local ret = {}
	for line in data:gmatch("[^\r\n]+") do
		local time = time_to_secs(line)
		if time and (time < video_length) then
			table.insert(ret, { time = time, title = line })
		end
	end
	table.sort(ret, function(a, b)
		return a.time < b.time
	end)
	return ret
end
local function chapters()
	if json.chapters then
		for i = 1, #json.chapters do
			local chapter = json.chapters[i]
			local title = chapter.title or ""
			if title == "" then
				title = string.format("Chapter %02d", i)
			end
			table.insert(chapter_list, { time = chapter.start_time, title = title })
		end
	elseif not (json.description == nil) and not (json.duration == nil) then
		chapter_list = extract_chapters(json.description, json.duration)
	end
end
--end ytdl_hook

local title = ""
local fVideo = ""
local fAudio = ""
local dvID = ""
local function load_files(dtitle, destination, audio, wait)
	if wait then
		if utils.file_info(destination .. ".mka") then
			print("---wait success: found mka---")
			audio = 'audio-file="' .. destination .. '.mka",'
		else
			print("---could not find mka after wait, audio may be missing---")
		end
	end
	local destMKV = destination .. ".mkv"
	local loadOpts = audio .. 'force-media-title="' .. dtitle .. '",demuxer-max-back-bytes=1MiB,demuxer-max-bytes=3MiB,ytdl=no,script-opt=ytdl_preload-id=' .. dvID
	if useNewLoadfile() then
		local commandTable = { name = "loadfile" , url = destMKV, flags = "append", index = -1, options = loadOpts}
		mp.command_native(commandTable)
	else
		mp.commandv(
			"loadfile",
			destination .. ".mkv",
			"append",
			audio .. 'force-media-title="' .. dtitle .. '",demuxer-max-back-bytes=1MiB,demuxer-max-bytes=3MiB,ytdl=no'
		)
	end
	mp.commandv("playlist_move", mp.get_property("playlist-count") - 1, nextIndex)
	mp.commandv("playlist_remove", nextIndex + 1)
	caught = true
	title = ""
end

local function listener(event)
	if not caught and event.prefix == mp.get_script_name() and string.find(event.text, "%[download%] Destination: ") then
		local destination = title
		if destination and string.find(destination, string.gsub(cachePath, "~/", "")) then
			mp.unregister_event(listener)
			_, title = utils.split_path(destination)
			table.insert(filesToDelete, title)
			local audio = ""
			if fAudio == "" then
				load_files(title, destination, audio, false)
			else
				if utils.file_info(destination .. ".mka") then
					audio = 'audio-file="' .. destination .. '.mka",'
					load_files(title, destination, audio, false)
				else
					print("---expected mka but could not find it, waiting for 2 seconds---")
					mp.add_timeout(2, function()
						load_files(title, destination, audio, true)
					end)
				end
			end
		end
	end
end

--from ytdl_hook
mp.add_hook("on_preloaded", 10, function()
	if string.find(mp.get_property("path"), cachePath) then
		chapters()
		if next(chapter_list) ~= nil then
			mp.set_property_native("chapter-list", chapter_list)
			chapter_list = {}
			json = ""
		end
	end
end)
--end ytdl_hook

local function addOPTS(old, fdrop)
	for i=1,99 do
		local opt = mp.get_opt(mp.get_script_name().."-ytdl_opt"..i)
		if opt ~= nil then
			additionalOpts["ytdl_opt"..i] = opt
		end
	end
	for k, v in pairs(additionalOpts) do
		if string.find(v, "%s") then
			for l, w in string.gmatch(v, "([-%w]+) (.+)") do
				if fdrop==false or (fdrop==true and l~="-f" and l~="--format") then
					table.insert(old, l)
					w = string.gsub(w,'"','')
					table.insert(old, w)
				end
			end
		else
			table.insert(old, v)
		end
	end
	return old
end

local AudioDownloadHandle = {}
local VideoDownloadHandle = {}
local JsonDownloadHandle = {}
local function download_files(success, result, error)

	if result.killed_by_us then
		print("killed")
		return
	end
	if result.stderr ~= "" and result.stderr:find("ERROR") then
		print(result.stderr)

		local keep = opts.keep_faults
		if toggleFaults ~= "" then
			keep = toggleFaults
		elseif mp.get_opt("ytdl_preload_keep_faults")~=nil then
			keep = tostring(mp.get_opt("ytdl_preload_keep_faults"))
		end
		if keep=="false" then
			print("removing faulty video (entry number: " .. nextIndex + 1 .. ") from playlist")
			mp.commandv("playlist-remove", nextIndex)
		else
			print("keeping faulty video (entry number: " .. nextIndex + 1 .. ") as URL")
		end
		caught = true
		return
	end

	json = utils.parse_json(result.stdout)
	if json._type == "playlist" then
		print("playlist detected. abort")
		return
	end
	-- local jio = io.open("t.json", "w")
	-- jio:write(result.stdout)
	-- jio:close()
	title = string.match(json.requested_downloads[1].filename, "(.+)%.[%d%w]+")
	dvID = json.id or ""
	fVideo = json.format_id
	if fVideo:find("+") then
		fAudio = string.match(fVideo, "%+([^/]+)")
		fVideo = string.match(fVideo, "([^/+]+)%+")
		local args = {
			ytdl,
			"--no-continue",
			"-q",
			"-f",
			fAudio,
			restrictFilenames,
			"--no-playlist",
			"--no-part",
			"-o",
			cachePath .. pathSep .. "%(title)s.mka",
			"--load-info-json",
			json.requested_downloads[1].infojson_filename,
		}
		args = addOPTS(args, true)
		AudioDownloadHandle = mp.command_native_async({
			name = "subprocess",
			args = args,
			playback_only = false,
		}, function() end)
	end

	local args = {
		ytdl,
		"--fixup",
		"never",
		"--no-continue",
		"-f",
		fVideo,
		restrictFilenames,
		"--no-playlist",
		"--no-part",
		"-o",
		cachePath .. pathSep .. "%(title)s.mkv",
		"--load-info-json",
		json.requested_downloads[1].infojson_filename,
	}
	args = addOPTS(args, true)
	VideoDownloadHandle = mp.command_native_async({
		name = "subprocess",
		args = args,
		playback_only = false,
	}, function() end)
	mp.register_event("log-message", listener)
end

local enabled = true
local function DL()
	local enabledOpt = tostring(mp.get_opt("enable_ytdl_preload"))

	if enabled == false then 
		enabledOpt = "false"
	end
	local index = tonumber(mp.get_property("playlist-pos"))
	if tonumber(mp.get_property("playlist-count")) > 1 and index == tonumber(mp.get_property("playlist-count")) - 1 then
		index = -1
	end

	if (enabledOpt and enabledOpt=="false") or
		(tonumber(mp.get_property("playlist-count")) == 1) or
		(not mp.get_property("playlist/" .. index + 1 .. "/filename"):find("://", 0, false))
	then
		return
	end

	nextIndex = index + 1
	local nextFile = mp.get_property("playlist/" .. nextIndex .. "/filename")
	if nextFile and caught then
		caught = false
		mp.enable_messages("info")
		local args = {
			ytdl,
			"--dump-single-json",
			"--write-info-json",
			"--write-subs",
			"--no-simulate",
			"--skip-download",
			restrictFilenames,
			"--no-playlist",
			"--flat-playlist",
			"--no-part",
			"-o",
			cachePath .. pathSep .. "%(title)s.%(ext)s",
			nextFile,
		}
		args = addOPTS(args, false)
		local getFormat=true
		for _,v in pairs(args) do
			if v=="-f" or v=="--format" then
				getFormat=false
			end
		end
		if getFormat and opts.format~=nil and opts.format~="" then
			table.insert(args,"-f")
			table.insert(args,opts.format)
		end
		JsonDownloadHandle = mp.command_native_async({
			name = "subprocess",
			args = args,
			capture_stdout = true,
			capture_stderr = true,
			playback_only = false,
		}, function(...)
			download_files(...)
		end)
	end
end

mp.add_hook("on_unload", 50, function()
	-- mp.abort_async_command(AudioDownloadHandle)
	-- mp.abort_async_command(VideoDownloadHandle)
	mp.abort_async_command(JsonDownloadHandle)
	mp.unregister_event(listener)
	caught = true
end)

local skipInitial
mp.observe_property("playlist-count", "number", function()
	if skipInitial then
		DL()
	else
		skipInitial = true
	end
end)

--from ytdl_hook
--local platform_is_windows = (pathSep == "\\")
local o = {
	exclude = "",
	try_ytdl_first = false,
	use_manifests = false,
	all_formats = false,
	force_all_formats = true,
	ytdl_path = "",
}
local paths_to_search = { "yt-dlp", "yt-dlp_x86", "youtube-dl" }

options.read_options(o, "ytdl_hook")

local separator = platform_is_windows and ";" or ":"
if o.ytdl_path:match("[^" .. separator .. "]") then
	paths_to_search = {}
	for path in o.ytdl_path:gmatch("[^" .. separator .. "]+") do
		table.insert(paths_to_search, path)
	end
end

local function exec(args)
	local ret = mp.command_native({
		name = "subprocess",
		args = args,
		capture_stdout = true,
		capture_stderr = true,
	})
	return ret.status, ret.stdout, ret, ret.killed_by_us
end

local msg = require("mp.msg")
local command = {}
for _, path in pairs(paths_to_search) do
	-- search for youtube-dl in mpv's config dir
	local exesuf = platform_is_windows and ".exe" or ""
	local ytdl_cmd = mp.find_config_file(path .. exesuf)
	if ytdl_cmd then
		msg.verbose("Found youtube-dl at: " .. ytdl_cmd)
		ytdl = ytdl_cmd
		break
	else
		msg.verbose("No youtube-dl found with path " .. path .. exesuf .. " in config directories")
		--search in PATH
		command[1] = path
		es, json, result, aborted = exec(command)
		if result.error_string == "init" then
			msg.verbose("youtube-dl with path " .. path .. exesuf .. " not found in PATH or not enough permissions")
		else
			msg.verbose("Found youtube-dl with path " .. path .. exesuf .. " in PATH")
			ytdl = path
			break
		end
	end
end
--end ytdl_hook

if platform_is_windows then
	restrictFilenames = "--windows-filenames"
end

mp.register_event("start-file", DL)

local function deletePreload(hash)
	if platform_is_windows then
		os.execute('del /Q /F "' .. cachePath .. '\\*' .. hash .. '*" >nul 2>nul')
	else
		hash = hash:gsub(" ","\\ ")
		os.execute("rm -f " .. cachePath .. "/*" .. hash .. "* &> /dev/null")
	end
end

mp.register_event("shutdown", function()
	mp.abort_async_command(AudioDownloadHandle)
	mp.abort_async_command(VideoDownloadHandle)
	mp.abort_async_command(JsonDownloadHandle)
	local ftd = io.open(cachePath .. "/temp.files", "a")
	if ftd then
		for k, v in pairs(filesToDelete) do
			ftd:write(v .. "\n")
			deletePreload(v)
		end
		ftd:close()
	end
	deletePreload(".info.json")
end)
local ftd = io.open(cachePath .. "/temp.files", "r")
while ftd ~= nil do
	local line = ftd:read()
	if line == nil or line == "" then
		ftd:close()
		io.open(cachePath .. "/temp.files", "w"):close()
		break
	end
	deletePreload(line)
end
deletePreload(".info.json")

mp.add_key_binding("Y", "toggle_ytdl_preload", function()
	enabled = not enabled
	if enabled == true then DL() end
	mp.osd_message("enable_ytdl_preload="..tostring(enabled))
end)

mp.add_key_binding("Ctrl+f", "toggle_keep_faults", function()
	if toggleFaults == "" then
		toggleFaults = tostring(mp.get_opt(mp.get_script_name().."_keep_faults")) or opts.keep_faults
	end
	if toggleFaults == "true" then
		toggleFaults = "false"
	else
		toggleFaults = "true"
	end
	mp.osd_message("keep_faults="..tostring(toggleFaults))
end)
