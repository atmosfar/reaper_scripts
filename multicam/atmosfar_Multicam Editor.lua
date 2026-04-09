-- @description Multicam editor
-- @author atmosfar
-- @version 0.21
-- @about
--   A multicam editor script which allows you to select the desired active angle on the multicam preview grid.
-- @links
--  Forum Thread https://forums.cockos.com/showthread.php?t=307612
--  GitHub repository https://github.com/atmosfar/reaper_scripts/tree/master/multicam
-- @provides
--  [data] multicam_video_processor.video_code > atmosfar_multicam/
-- @changelog
--  v0.3 - Added JS API function check, and second run check, TCP param controls.
--  v0.2 - Added SetupMulticamTrack() and SetupVideoProcessor() to automate project structuring.

reaper.gmem_attach("multicam")

local videoWnd = nil
local VIDEO_WINDOW_TITLE = reaper.LocalizeString("Video Window", "video2_DLG_102", 0)
local TARGET_ASPECT = 16 / 9
local _, video_width = reaper.get_config_var_string("projvidw")
local _, video_height = reaper.get_config_var_string("projvidh")
if tonumber(video_width) > 0 and tonumber(video_height) > 0 then
	TARGET_ASPECT = tonumber(video_width) / tonumber(video_height)
end
local last_mouse_cap = 0

function GetMulticamTrack()
	local proj = 0
	local track_count = reaper.CountTracks(proj)

	for i = 0, track_count - 1 do
		local track = reaper.GetTrack(proj, i)
		local _, track_name = reaper.GetTrackName(track)

		if track_name:lower() == "multicam" then
			return i
		end
	end
	return -1
end

function SetupMulticamTrack()
	reaper.Undo_BeginBlock()

	local proj = 0
	local track_count = reaper.CountTracks(proj)
	local last_selected_index = -1
	local tracks_selected = false

	for i = 0, track_count - 1 do
		local track = reaper.GetTrack(proj, i)
		if track then
			if reaper.IsTrackSelected(track) then
				last_selected_index = i
				tracks_selected = true
			end
		end
	end

	if not tracks_selected then
		reaper.MB("Error creating Multitrack folder structure: No tracks selected", "Multicam Editor Setup", 0)
		reaper.Undo_EndBlock("Setup multicam track", 0)
		return -1
	end

	local multicam_track = last_selected_index + 1
	-- Add multicam track after the last selected track
	reaper.InsertTrackInProject(proj, multicam_track, 0)

	local new_track = reaper.GetTrack(proj, multicam_track)
	-- Rename the new track
	reaper.GetSetMediaTrackInfo_String(new_track, "P_NAME", "Multicam", true)
	-- Set the track param envelope automation mode to "Touch"
	reaper.SetMediaTrackInfo_Value(new_track, "I_AUTOMODE", 2)

	local selected_count = reaper.CountSelectedTracks(proj)
	-- Move selected tracks into multicam folder
	reaper.ReorderSelectedTracks(multicam_track + 1, 1)
	reaper.Main_OnCommand(40297, 0) -- Deselect all tracks
	reaper.Undo_EndBlock("Setup multicam track", 0)
	-- Multicam track's index has changed after child tracks moved below it
	return multicam_track - selected_count
end

local function SetupVideoProcessor(tr)
	local filename = reaper.GetResourcePath() .. "/Data/atmosfar_multicam/multicam_video_processor.video_code"
	local video_code = nil

	local file = io.open(filename, "r")
	if file then
		video_code = file:read("*all")
		file:close()
		if video_code and video_code ~= "" then
			-- Add FX
      local proj = 0
      local track = reaper.GetTrack(proj, tr)
			local fx_index = reaper.TrackFX_AddByName(track, "Video processor", false, 1)
			if fx_index ~= -1 then
				reaper.TrackFX_SetNamedConfigParm(track, fx_index, "VIDEO_CODE", video_code)
				-- Add track TCP controls if SWS is installed
				if type(reaper.SNM_AddTCPFXParm) == "function" then
					reaper.SNM_AddTCPFXParm(track, 0, 2) -- Display Mode
					reaper.SNM_AddTCPFXParm(track, 0, 1) -- Active Angle
				end
				return true
			end
		else
			reaper.MB("Error in SetupVideoProcessor(): File is empty or unreadable", "Multicam Editor", 0)
			return false
		end
	else
		reaper.MB("Error in SetupVideoProcessor(): cannot open file " .. filename, "Multicam Editor", 0)
		return false
	end
end

local function IsVideoWindowValid(hwnd)
	if not hwnd then
		return false
	end

	-- Check if window is still valid and has expected title
	local title = reaper.JS_Window_GetTitle(hwnd)
	if title == VIDEO_WINDOW_TITLE then
		return true
	end

	-- Fallback: handle might be invalid, or title changed
	return false
end

local function FindVideoWindow()
	-- If cached handle is valid, return it immediately
	if IsVideoWindowValid(videoWnd) then
		return videoWnd
	end

	-- Re-scan if cached handle is missing or invalid
	videoWnd = nil

	-- 1. Try direct find (most common for docked/undocked changes)
	videoWnd = reaper.JS_Window_Find(VIDEO_WINDOW_TITLE, true)
	if IsVideoWindowValid(videoWnd) then
		return videoWnd
	end

	-- 2. Try find child of main window
	local mainHwnd = reaper.GetMainHwnd()
	videoWnd = reaper.JS_Window_FindChild(mainHwnd, VIDEO_WINDOW_TITLE, true)
	if IsVideoWindowValid(videoWnd) then
		return videoWnd
	end

	-- 3. Fallback: enumerate all children
	local retval, list = reaper.JS_Window_ListAllChild(mainHwnd)
	if retval and list then
		for address in list:gmatch("[^,]+") do
			local a = tonumber(address)
			if a ~= nil then
				local hwnd = reaper.JS_Window_HandleFromAddress(a)
				if IsVideoWindowValid(hwnd) then
					videoWnd = hwnd
					return videoWnd
				end
			end
		end
	end

	return nil
end

-- Count tracks with video items
local function CountVideoTracks()
	local video_tracks = reaper.gmem_read(0) or 0
	return video_tracks
end

-- Ensure the envelope uses square points (DEFSHAPE 1)
local function EnsureSquarePoints(env)
	local retval, xml_env = reaper.GetEnvelopeStateChunk(env, "", false)
	if retval then
		local new_xml = xml_env:gsub("DEFSHAPE%s%d", "DEFSHAPE 1")
		if new_xml ~= xml_env then
			reaper.SetEnvelopeStateChunk(env, new_xml, false)
		end
	end
end

-- Helper to find the Active Angle envelope
local function GetActiveAngleEnvelope()
	local track_count = reaper.CountTracks(0)
	local envelope = nil
	for i = 0, track_count - 1 do
		local track = reaper.GetTrack(0, i)
		local fx_count = reaper.TrackFX_GetCount(track)
		for j = 0, fx_count - 1 do
			local _, name = reaper.TrackFX_GetFXName(track, j)
			if name:lower():match("video processor") and name:lower():match("multicam grid layout") then
				envelope = reaper.GetFXEnvelope(track, j, 1, true) -- Param 1 is Active Angle
				break
			end
		end
	end
	return envelope
end

-- Perform the Multicam Switch: Insert Envelope Point
local function PerformSwitch(clicked_idx)
	local selected_angle = clicked_idx + 1
	local cursor_pos
	if reaper.GetPlayState() == 1 then
		cursor_pos = reaper.GetPlayPosition()
	else
		cursor_pos = reaper.GetCursorPosition()
	end

	reaper.Undo_BeginBlock()

	local envelope = GetActiveAngleEnvelope()
	if envelope then
		local closest_point_index = reaper.GetEnvelopePointByTime(envelope, cursor_pos)
		local _, time, value = reaper.GetEnvelopePoint(envelope, closest_point_index)
		local existing_point = (time == cursor_pos)
		local new_angle = (value ~= selected_angle)
		if existing_point then
			if new_angle then
				reaper.SetEnvelopePoint(envelope, closest_point_index, cursor_pos, selected_angle, 1, 0, false, true)
			end
		else
			reaper.InsertEnvelopePoint(envelope, cursor_pos, selected_angle, 1, 0, false, true)
		end
		reaper.Envelope_SortPoints(envelope)
	end

	reaper.UpdateArrange()
	reaper.Undo_EndBlock("Multicam Switch (Envelope)", -1)
end

-- Main function
local function Main()
	local wnd = FindVideoWindow()
	if not wnd then
		reaper.defer(Main)
		return
	end

	local _, left, top, right, bottom = reaper.JS_Window_GetRect(wnd)
	local win_w = math.abs(right - left)
	local win_h = math.abs(bottom - top)

	-- Calculate actual video area (16:9) centered in the window
	local view_w, view_h
	local cur_aspect = win_w / win_h

	if cur_aspect > TARGET_ASPECT then
		-- Pillarbox (Black bars on sides)
		view_h = win_h
		view_w = win_h * TARGET_ASPECT
	else
		-- Letterbox (Black bars on top/bottom)
		view_w = win_w
		view_h = win_w / TARGET_ASPECT
	end

	local offset_x = (win_w - view_w) / 2
	local offset_y = (win_h - view_h) / 2

	local mx, my = reaper.GetMousePosition()
	local is_macos = reaper.GetOS():match("OSX") or reaper.GetOS():match("macOS")

	-- Map mouse to window local
	local lx, ly
	if is_macos then
		lx = mx - left
		ly = top - my
	else
		lx = mx - left
		ly = my - top
	end

	-- Check if mouse is inside the actual 16:9 video area
	if lx >= offset_x and lx < (offset_x + view_w) and ly >= offset_y and ly < (offset_y + view_h) then
		local mouse_cap = reaper.JS_Mouse_GetState(1)
		if mouse_cap == 1 and last_mouse_cap == 0 then
			-- Normalize relative to the video area only
			local nx = (lx - offset_x) / view_w
			local ny = (ly - offset_y) / view_h

			local num_found = CountVideoTracks()
			if num_found > 0 then
				local cols = math.ceil(math.sqrt(num_found))
				local rows = math.ceil(num_found / cols)

				local col_pos = math.floor(nx * cols)
				local row_pos = math.floor(ny * rows)
				local clicked_idx = (row_pos * cols) + col_pos

				if clicked_idx < num_found then
					PerformSwitch(clicked_idx)
				end
			end
		end
		last_mouse_cap = mouse_cap
	else
		last_mouse_cap = 0
	end

	reaper.defer(Main)
end

-- INITIALIZATION
if type(reaper.JS_Mouse_GetState) ~= "function" then
	reaper.MB("js_ReaScriptAPI missing, please install it from ReaPack.", "Error: Multicam Editor", 0)
	return
end

local multicam_track = GetMulticamTrack()
if multicam_track == -1 then
	multicam_track = SetupMulticamTrack()
	if multicam_track == -1 then
		return
	end
	local processor_setup = SetupVideoProcessor(multicam_track)
	if not processor_setup then
		return
	end
end

local start_env = GetActiveAngleEnvelope()
if start_env then
	EnsureSquarePoints(start_env)
end
Main()
