-- @description Multicam editor
-- @author atmosfar
-- @version 0.1
-- @about
--   A multicam editor script which allows you to select the desired active angle on the multicam preview grid.
-- @links
--  Forum Thread https://forums.cockos.com/showthread.php?t=307612
--  GitHub repository https://github.com/atmosfar/reaper_scripts/tree/master/multicam

reaper.gmem_attach("multicam")

local videoWnd = nil
local VIDEO_WINDOW_TITLE = reaper.LocalizeString('Video Window', 'video2_DLG_102', 0)
local TARGET_ASPECT = 16 / 9
local _, video_width = reaper.get_config_var_string("projvidw")
local _, video_height = reaper.get_config_var_string("projvidh")
if (tonumber(video_width) > 0 and tonumber(video_height) > 0) then
  TARGET_ASPECT =  tonumber(video_width) / tonumber(video_height)
end

local function IsVideoWindowValid(hwnd)
  if not hwnd then return false end
  
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
  if IsVideoWindowValid(videoWnd) then return videoWnd end
  
  -- 2. Try find child of main window
  local mainHwnd = reaper.GetMainHwnd()
  videoWnd = reaper.JS_Window_FindChild(mainHwnd, VIDEO_WINDOW_TITLE, true)
  if IsVideoWindowValid(videoWnd) then return videoWnd end
  
  -- 3. Fallback: enumerate all children
  local retval, list = reaper.JS_Window_ListAllChild(mainHwnd)
  if retval and list then
    for address in list:gmatch("[^,]+") do
      local hwnd = reaper.JS_Window_HandleFromAddress(address)
      if IsVideoWindowValid(hwnd) then
        videoWnd = hwnd
        return videoWnd
      end
    end
  end
  
  return nil
end


-- Count tracks with video items
local function CountVideoTracks()
  video_tracks = reaper.gmem_read(0) or 0
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
      if name:lower():match("video processor") and 
        name:lower():match("multicam grid layout") then
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
  else
    reaper.MB("Multicam video processor track not found", "Error", 0)
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
  
  local retval, left, top, right, bottom = reaper.JS_Window_GetRect(wnd)
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
  if lx >= offset_x and lx < (offset_x + view_w) and 
     ly >= offset_y and ly < (offset_y + view_h) then
    
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
local start_env = GetActiveAngleEnvelope()
if start_env then EnsureSquarePoints(start_env) end

last_mouse_cap = 0
Main()
