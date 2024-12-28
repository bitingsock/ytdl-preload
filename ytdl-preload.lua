----------------------
-- #example ytdl_preload.conf
-- # make sure lines do not have trailing whitespace
-- # ytdl_opt has no sanity check and should be formatted exactly how it would appear in yt-dlp CLI, they are split into a key/value pair on whitespace
-- # at least on Windows, do not escape '\' in temp, just us a single one for each divider

-- #temp=R:\ytdltest
-- #subLangs = "en",
-- #ytdl_opt1=-r 50k
-- #ytdl_opt2=-N 5
-- #ytdl_opt#=etc
----------------------
local nextIndex
local caught = true
-- local pop = false
local ytdl = "yt-dlp"
local utils = require 'mp.utils'

local options = require 'mp.options'
local opts = {
	temp = "R:\\ytdl",
	subLangs = "en",
	ytdl_opt1 = "",
	ytdl_opt2 = "",
	ytdl_opt3 = "",
	ytdl_opt4 = "",
	ytdl_opt5 = "",
	ytdl_opt6 = "",
	ytdl_opt7 = "",
	ytdl_opt8 = "",
	ytdl_opt9 = "",
}
options.read_options(opts, "ytdl_preload")
-- print(opts.temp)
local additionalOpts = {}
for k, v in pairs(opts) do
	if k:find("ytdl_opt%d") and v ~= "" then
		additionalOpts[k] = v
		-- print("entry")
		-- print(k .. v)
	end
end
local cachePath = opts.temp

local restrictFilenames = "--no-restrict-filenames"
local chapter_list = {}
local json = ""
local filesToDelete = {}

local function exists(file)
	local ok, err, code = os.rename(file, file)
	if not ok then
		if code == 13 then -- Permission denied, but it exists
			return true
		end
	end
	return ok, err
end
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
	table.sort(ret, function(a, b) return a.time < b.time end)
	return ret
end
local function chapters()
	if json.chapters then
		for i = 1, #json.chapters do
			local chapter = json.chapters[i]
			local title = chapter.title or ""
			if title == "" then
				title = string.format('Chapter %02d', i)
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
local function load_files(dtitle, destination, audio, wait)
	if wait then
		if exists(destination .. ".mka") then
			print("---wait success: found mka---")
			audio = "audio-file=" .. destination .. '.mka,'
		else
			print("---could not find mka after wait, audio may be missing---")
		end
	end
	-- if audio ~= "" then
	-- 	table.insert(filesToDelete, destination .. ".mka")
	-- end
	-- table.insert(filesToDelete, destination .. ".mkv")
	dtitle = dtitle:gsub("-" .. ("[%w_-]"):rep(11) .. "$", "")
	dtitle = dtitle:gsub("^" .. ("%d"):rep(10) .. "%-", "")
	if useNewLoadfile() then
		mp.commandv("loadfile", destination .. ".mkv", "append", -1,
			audio .. 'force-media-title="' .. dtitle .. '",demuxer-max-back-bytes=1MiB,demuxer-max-bytes=3MiB,ytdl=no')
	else
		mp.commandv("loadfile", destination .. ".mkv", "append",
			audio .. 'force-media-title="' .. dtitle .. '",demuxer-max-back-bytes=1MiB,demuxer-max-bytes=3MiB,ytdl=no')                                                --,sub-file="..destination..".en.vtt") --in case they are not set up to autoload
	end
	mp.commandv("playlist_move", mp.get_property("playlist-count") - 1, nextIndex)
	mp.commandv("playlist_remove", nextIndex + 1)
	caught = true
	title = ""
	-- pop = true
end

local listenID = ""
local function listener(event)
	if not caught and event.prefix == mp.get_script_name() and string.find(event.text, listenID) then
		local destination = string.match(event.text, "%[download%] Destination: (.+).mkv") or
			string.match(event.text, "%[download%] (.+).mkv has already been downloaded")
		-- if destination then print("---"..cachePath) end;
		if destination and string.find(destination, string.gsub(cachePath, '~/', '')) then
			-- print(listenID)
			mp.unregister_event(listener)
			_, title = utils.split_path(destination)
			local audio = ""
			if fAudio == "" then
				load_files(title, destination, audio, false)
			else
				if exists(destination .. ".mka") then
					audio = "audio-file=" .. destination .. '.mka,'
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
function dump(o)
	if type(o) == 'table' then
		local s = '{ '
		for k, v in pairs(o) do
			if type(k) ~= 'number' then k = '"' .. k .. '"' end
			s = s .. '[' .. k .. '] = ' .. dump(v) .. ','
		end
		return s .. '} '
	else
		return tostring(o)
	end
end

local function addOPTS(old)
	for k, v in pairs(additionalOpts) do
		-- print(k)
		if string.find(v, "%s") then
			for l, w in string.gmatch(v, "([-%w]+) (.+)") do
				table.insert(old, l)
				table.insert(old, w)
			end
		else
			table.insert(old, v)
		end
	end
	-- print(dump(old))
	return old
end

local AudioDownloadHandle = {}
local VideoDownloadHandle = {}
local JsonDownloadHandle = {}
local function download_files(id, success, result, error)
	if result.killed_by_us then
		mp.unregister_event(listener)
		return
	end
	if result.stderr ~= '' and result.stderr:find("ERROR") then
		print(result.stderr)
		mp.unregister_event(listener)
		print("removing faulty video (entry number: " .. nextIndex + 1 .. ") from playlist")
		caught = true
		mp.commandv("playlist-remove", nextIndex);
		return
	end
	local jfile = cachePath .. "/" .. id .. ".json"

	local jfileIO = io.open(jfile, "w")
	jfileIO:write(result.stdout)
	jfileIO:close()
	json = utils.parse_json(result.stdout)
	-- print(dump(json))
	if json.requested_downloads[1].requested_formats ~= nil then
		local args = { ytdl, "--no-continue", "-q", "-f", fAudio,restrictFilenames, "--no-playlist", "--no-part",
			"-o", cachePath .. "/" .. id .. "-%(title)s-%(id)s.mka", "--load-info-json", jfile }
		args = addOPTS(args)
		AudioDownloadHandle = mp.command_native_async({
			name = "subprocess",
			args = args,
			playback_only = false
		}, function()
		end)
	else
		fAudio = ""
		fVideo = fVideo:gsub("bestvideo", "best")
		fVideo = fVideo:gsub("bv", "best")
	end

	local args = { ytdl, "--no-continue", "-f", fVideo .. '/best',restrictFilenames, "--no-playlist",
		"--no-part", "-o", cachePath .. "/" .. id .. "-%(title)s-%(id)s.mkv", "--load-info-json", jfile }
	args = addOPTS(args)
	VideoDownloadHandle = mp.command_native_async({
		name = "subprocess",
		args = args,
		playback_only = false
	}, function()
	end)
end

local function DL()
	local index = tonumber(mp.get_property("playlist-pos"))
	if tonumber(mp.get_property("playlist-count")) > 1 and index == tonumber(mp.get_property("playlist-count")) - 1 then
		index = -1
	end
	if index >= 0 and mp.get_property("playlist/" .. index .. "/filename"):find("/videos$") and mp.get_property("playlist/" .. index + 1 .. "/filename"):find("/shorts$") then
		return
	end
	if tonumber(mp.get_property("playlist-pos-1")) > 0 then
		-- print(index)
		nextIndex = index + 1
		local nextFile = mp.get_property("playlist/" .. nextIndex .. "/filename")
		if nextFile and caught and nextFile:find("://", 0, false) then
			caught = false
			mp.enable_messages("info")
			mp.register_event("log-message", listener)
			local ytFormat = mp.get_property("ytdl-format")
			fVideo = string.match(ytFormat, '(.+)%+.+//?') or 'bestvideo'
			fAudio = string.match(ytFormat, '.+%+(.+)//?') or 'bestaudio'
			-- print("start"..nextFile)
			listenID = tostring(os.time())
			local args = { ytdl, "--dump-single-json", "--no-simulate", "--skip-download",
				restrictFilenames,
				"--no-playlist", "--sub-langs", opts.subLangs, "--write-sub", "--no-part", "-o",
				cachePath .. "/" .. listenID .. "-%(title)s-%(id)s.%(ext)s", nextFile }
			args = addOPTS(args)
			-- print(dump(args))
			table.insert(filesToDelete, listenID)
			JsonDownloadHandle = mp.command_native_async({
				name = "subprocess",
				args = args,
				capture_stdout = true,
				capture_stderr = true,
				playback_only = false
			}, function(...)
				download_files(listenID, ...)
			end)
		end
	end
end

local function clearCache()
	-- print(pop)

	--if pop == true then
	mp.abort_async_command(AudioDownloadHandle)
	mp.abort_async_command(VideoDownloadHandle)
	mp.abort_async_command(JsonDownloadHandle)
	-- for k, v in pairs(filesToDelete) do
	-- 	print("remove: " .. v)
	-- 	os.remove(v)
	-- end
	local ftd = io.open(cachePath .. "/temp.files", "a")
	for k, v in pairs(filesToDelete) do
		ftd:write(v .. "\n")
		if package.config:sub(1, 1) ~= '/' then
			os.execute('del /Q /F "' .. cachePath .. "\\" .. v .. '*"')
		else
			os.execute('rm -f ' .. cachePath .. "/" .. v .. "*")
		end
	end
	ftd:close()
	print('clear')
	mp.command("quit")
	--end
end
mp.add_hook("on_unload", 50, function()
	-- mp.abort_async_command(AudioDownloadHandle)
	-- mp.abort_async_command(VideoDownloadHandle)
	mp.abort_async_command(JsonDownloadHandle)
	mp.unregister_event(listener)
	caught = true
	listenID = "resetYtdlPreloadListener"
	-- print(listenID)
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
local platform_is_windows = (package.config:sub(1, 1) == "\\")
local o = {
	exclude = "",
	try_ytdl_first = false,
	use_manifests = false,
	all_formats = false,
	force_all_formats = true,
	ytdl_path = "",
}
local paths_to_search = { "yt-dlp", "yt-dlp_x86", "youtube-dl" }
--local options = require 'mp.options'
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
		capture_stderr = true
	})
	return ret.status, ret.stdout, ret, ret.killed_by_us
end

local msg = require 'mp.msg'
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
	restrictFilenames = "--restrict-filenames"
end

mp.register_event("start-file", DL)
mp.register_event("shutdown", clearCache)
local ftd = io.open(cachePath .. "/temp.files", "r")
while ftd ~= nil do
	local line = ftd:read()
	if line == nil or line == "" then
		ftd:close()
		io.open(cachePath .. "/temp.files", "w"):close()
		break
	end
	-- print("DEL::"..line)
	if package.config:sub(1, 1) ~= '/' then
		os.execute('del /Q /F "' .. cachePath .. "\\" .. line .. '*" >nul 2>nul')
	else
		os.execute('rm -f ' .. cachePath .. "/" .. line .. "* &> /dev/null")
	end
end
