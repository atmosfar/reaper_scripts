-- @description atmosfar - Render audio and remux video
-- @author atmosfar
-- @version 1.0
-- @about
--   A script which renders the current project as WAV, and remuxes it into a new video file with the video stream from the first video item found in the project, without re-encoding.
-- @links
--  Forum Thread https://forums.cockos.com/showthread.php?t=307612
--  GitHub repository https://github.com/atmosfar/reaper_scripts/tree/master/ffmpeg_remux
-- @changelog
--  v1.0 - Initial release


-- FFMPEG path retrieval code below is from Saxmand_VideoCutDetectionEditor 
-- (https://forums.cockos.com/showthread.php?t=306113)
----------------------------------------------------------------------

-- Helper functions to locate and verify ffmpeg
local FFmpegPathKey = "FFMPEG_PATH"
local ffmpegSectionName = "FFMPEG_STATE"

local function backwardsCompatabilityForVideoCutDetector()
    -- Migrate old state if present
    local oldState = "Saxmand_VideoCutDetectionEditor"
    if reaper.HasExtState(oldState, FFmpegPathKey) then
        reaper.SetExtState(ffmpegSectionName, FFmpegPathKey, reaper.GetExtState(oldState, FFmpegPathKey), true)
    end
end

-- Test whether a given binary responds to -version
local function test_ffmpeg(test_path)
    if not test_path or test_path == "" then return false end
    local cmd = string.format('"%s" -version', test_path)
    local result = reaper.ExecProcess(cmd, 1000)
    if result and (result:find("ffmpeg version") or result:find("configuration:")) then
        return true
    end
    return false
end

-- Prompt user to locate ffmpeg if not already known
local function acquire_ffmpeg_path()
    backwardsCompatabilityForVideoCutDetector()
    local path = nil
    if reaper.HasExtState(ffmpegSectionName, FFmpegPathKey) then
        path = reaper.GetExtState(ffmpegSectionName, FFmpegPathKey)
    else
        local is_windows = package.config:sub(1, 1) == "\\"
        local retval = reaper.MB("FFMpeg is required for this action. Find the path to your FFmpeg executable now or click Cancel.", "Find FFMpeg", 1)
        if retval == 1 then
            retval, path = reaper.GetUserFileNameForRead(is_windows and "" or "/usr/local/bin/", "Find FFMpeg executable", is_windows and "exe" or "")
            if retval then
                reaper.SetExtState(ffmpegSectionName, FFmpegPathKey, path, true)
                return acquire_ffmpeg_path() -- retry with newly saved path
            end
        else
            return nil
        end
    end
    if test_ffmpeg(path) then
        return path
    else
        reaper.MB("FFmpeg check failed.\nThe file at:\n" .. tostring(path) .. "\n\ndid not respond to '-version' command correctly.\nPlease check if the file is valid.", "Find FFMpeg Error", 0)
        reaper.DeleteExtState(ffmpegSectionName, FFmpegPathKey, true)
        return acquire_ffmpeg_path()
    end
end

-- Retrieve a valid ffmpeg path (cached in ExtState)
local function get_ffmpeg_path()
    if reaper.HasExtState(ffmpegSectionName, FFmpegPathKey) then
        local path = reaper.GetExtState(ffmpegSectionName, FFmpegPathKey)
        if path ~= "" and test_ffmpeg(path) then
            return path
        else
            reaper.DeleteExtState(ffmpegSectionName, FFmpegPathKey, true)
        end
    end
    return acquire_ffmpeg_path()
end

-- Remuxing code ---------------------------------------------------------

local function getFirstVideoItemPath()
    local itemCount = reaper.CountMediaItems(0)
    for i = 0, itemCount-1 do
        local item = reaper.GetMediaItem(0, i)
        if item then
            local _, stateChunk = reaper.GetItemStateChunk(item, "", false)
            if stateChunk and stateChunk:find("<SOURCE VIDEO") then
                local take = reaper.GetActiveTake(item)
                if take then
                    local source = reaper.GetMediaItemTake_Source(take)
                    if source then
                        local path = reaper.GetMediaSourceFileName(source)
                        -- Ignore false positive with M4A files
                        if path and #path > 0 and not path:lower():find("%.m4a$") then
                            return path
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function remuxVideo(videoPath, wavPath)
    local basePath = videoPath:match('(.+)%.%w+$') or videoPath
    local outPath
    local ext = videoPath:match('%.%w+$')
    if ext then
        local lower = string.lower(ext)
        if lower == '.mp4' or lower == '.mov' then
            outPath = basePath .. '_remuxed.mov'
        else
            outPath = basePath .. '_remuxed.mkv'
        end
    else
        outPath = basePath .. '_remuxed.mkv'
    end
    local ffmpegPath = get_ffmpeg_path()
    local cmd = string.format('%s -i "%s" -y -i "%s" -map 0:v:0 -map 1:a:0 -c copy "%s"', ffmpegPath, videoPath, wavPath, outPath)
    reaper.ShowConsoleMsg("Executing command:\n" .. cmd);
    local result = reaper.ExecProcess(cmd, -2)
    return result
end

local ffmpegPath = get_ffmpeg_path()
if not ffmpegPath then
    reaper.ShowMessageBox('ffmpeg not found. Please install ffmpeg and ensure it is in the system PATH.', 'Error', 0)
    return
end

local videoPath = getFirstVideoItemPath()
if not videoPath or videoPath == '' then
    reaper.ShowMessageBox('No video item found in the project.', 'Error', 0)
    return
end

if reaper.IsProjectDirty(0) ~= 0 then
    local choice = reaper.MB('The project is unsaved. Continue anyway?', 'Unsaved project', 1)
    if choice ~= 1 then
        return
    end
end

-- Set render pattern to the project name and format to WAV
local renderPattern = "$project"
local renderFormat = "WAV"
reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", renderPattern, true)
reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", renderFormat, true)
reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true) -- Render full project via master

reaper.Main_OnCommand(41824, 0)  -- Render project using latest settings

-- Retrieve the output path of the WAV render
local retval, wavPath = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
if not retval or not wavPath or wavPath == "" then
    reaper.ShowMessageBox("Failed to get WAV render target path.", "Error", 0)
    return
end

local result = remuxVideo(videoPath, wavPath)
if not result then
  reaper.ShowMessageBox("Error executing ffmpeg process", "Error", 0)
end
