--[[
    recording_alert.lua
    Plays .wav chimes and/or speech announcements when recording starts, stops, pauses or resumes.
    Requires OBS with LuaJIT FFI, winmm.dll (standard on Windows), SAPI.SpVoice (ole32/oleaut32), and shell32 for hidden VBS fallback.
]]

local obs  = obslua
local ffi  = require("ffi")

----------------------------------------------------------------------------
-- Configurable toggles for chimes and speech
----------------------------------------------------------------------------
local enable_chimes = true   -- change this to to false to disable the chimes
local enable_tts    = false   -- change this to true to enable spoken announcements
local enable_ss     = true    -- change this to false to disable the screenshot sound

----------------------------------------------------------------------------
-- If you'd like to use your own audio files, just add their paths here. They must be .wav files
----------------------------------------------------------------------------
local start_chime  = "C:\\Tools\\Beep\\start.wav"
local stop_chime   = "C:\\Tools\\Beep\\stop.wav"
local pause_chime  = "C:\\Tools\\Beep\\pause.wav"
local resume_chime = "C:\\Tools\\Beep\\resume.wav"
local screenshot_sound     = "C:\\Tools\\Beep\\screenshot.wav"

----------------------------------------------------------------------------
-- Define PlaySoundA, ShellExecuteA, and COM/SAPI interfaces
----------------------------------------------------------------------------
ffi.cdef[[
    /* PlaySoundA from winmm.dll */
    int PlaySoundA(const char* pszSound, void* hmod, unsigned int fdwSound);

    /* ShellExecuteA from shell32.dll */
    int ShellExecuteA(void* hwnd, const char* lpOperation,
                      const char* lpFile, const char* lpParameters,
                      const char* lpDirectory, int nShowCmd);

    /* GUID structure for COM */
    typedef struct {
      unsigned long  Data1;
      unsigned short Data2;
      unsigned short Data3;
      unsigned char  Data4[8];
    } GUID;

    /* COM core */
    long CoInitialize(void* pvReserved);
    void CoUninitialize(void);
    long CoCreateInstance(const GUID* rclsid, void* pUnkOuter,
                          unsigned long dwClsContext,
                          const GUID* riid, void** ppv);

    /* Definitions for ISpVoice vtable call */
    typedef struct ISpVoiceVtbl ISpVoiceVtbl;
    typedef struct ISpVoice {
        ISpVoiceVtbl* lpVtbl;
    } ISpVoice;
    typedef long (__stdcall *SpeakFn)(ISpVoice* this, const wchar_t* pwcs,
                                      unsigned long dwFlags, unsigned long* pulStreamNumber);

    unsigned short* SysAllocString(const wchar_t* psz);
    int SysFreeString(unsigned short* bstr);
]]

-- Load native libraries
local winmm    = ffi.load("winmm")
local shell32  = ffi.load("shell32")
local ole32    = ffi.load("ole32")
local oleaut32 = ffi.load("oleaut32")

local SW_HIDE = 0

----------------------------------------------------------------------------
-- Flags for PlaySoundA:
----------------------------------------------------------------------------
local SND_FILENAME  = 0x00020000
local SND_ASYNC     = 0x0001
local SND_NODEFAULT = 0x0002
local SND_NOWAIT    = 0x00002000

----------------------------------------------------------------------------
-- Helper function to play a .wav file with no popup
----------------------------------------------------------------------------
local function play_sound(path)
    local flags = bit.bor(SND_FILENAME, SND_ASYNC, SND_NODEFAULT, SND_NOWAIT)
    winmm.PlaySoundA(path, nil, flags)
end

----------------------------------------------------------------------------
-- Backup VBScript-based TTS fallback
----------------------------------------------------------------------------
local function speak_vbs(text)
    local tmp  = os.getenv("TEMP") or "."
    local file = tmp .. "\\obs_speak.vbs"
    local f = io.open(file, "w")
    if not f then return end
    f:write('Dim sapi\n')
    f:write('Set sapi = CreateObject("SAPI.SpVoice")\n')
    local safe = text:gsub('"', '""')
    f:write('sapi.Speak "' .. safe .. '"\n')
    f:close()
    -- launch hidden via wscript.exe
    local params = ('//nologo "%s"'):format(file)
    shell32.ShellExecuteA(nil, "open", "wscript.exe", params, nil, SW_HIDE)
end

----------------------------------------------------------------------------
-- Minimal FFI-based TTS (SAPI.SpVoice) setup
----------------------------------------------------------------------------
local CLSID_SpVoice = ffi.new("GUID", {
    0x96749377, 0x3391, 0x11D2,
    {0x9E,0xED,0x00,0xC0,0x4F,0x8E,0xFB,0x82}
})
local IID_ISpVoice = ffi.new("GUID", {
    0x6C44DF74, 0x72B9, 0x4992,
    {0xA1,0xEC,0xEF,0x99,0xE4,0x83,0x35,0x57}
})

local voice = nil

local function init_tts()
    local hr = ole32.CoInitialize(nil)
    if hr < 0 then
        print("[Lua: recording_alert.lua] TTS init failed: CoInitialize returned", hr)
        return
    end
    local pp = ffi.new("void*[1]")
    local cr = ole32.CoCreateInstance(CLSID_SpVoice, nil, 1, IID_ISpVoice, pp)
    if cr < 0 then
        print("[Lua: recording_alert.lua] TTS init failed: CoCreateInstance returned", cr)
        return
    end
    voice = ffi.cast("ISpVoice*", pp[0])
    print("[Lua: recording_alert.lua] TTS initialized successfully")
end

----------------------------------------------------------------------------
-- speak() tries FFI first, falls back to hidden VBS if needed
----------------------------------------------------------------------------
local function speak(text)
    if not enable_tts then return end
    if voice then
        -- FFI-based TTS
        local len  = #text
        local wbuf = ffi.new("wchar_t[?]", len + 1)
        for i = 1, len do wbuf[i - 1] = text:byte(i) end
        wbuf[len] = 0
        local bstr = oleaut32.SysAllocString(wbuf)
        local fn   = ffi.cast("SpeakFn", voice.lpVtbl[3])
        fn(voice, bstr, 0, nil)
        oleaut32.SysFreeString(bstr)
    else
        -- fallback via VBScript hidden
        speak_vbs(text)
    end
end

----------------------------------------------------------------------------
-- OBS event callback
----------------------------------------------------------------------------
function on_event(event)
    if     event == obs.OBS_FRONTEND_EVENT_RECORDING_STARTED then
        if enable_chimes then play_sound(start_chime) end
        speak("Recording started")

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_STOPPED then
        if enable_chimes then play_sound(stop_chime) end
        speak("Recording stopped")

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_PAUSED then
        if enable_chimes then play_sound(pause_chime) end
        speak("Recording paused")

    elseif event == obs.OBS_FRONTEND_EVENT_RECORDING_UNPAUSED then
        if enable_chimes then play_sound(resume_chime) end
        speak("Recording resumed")

    elseif event == obs.OBS_FRONTEND_EVENT_SCREENSHOT_TAKEN then
        if enable_ss then play_sound(screenshot_sound) end
		
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STARTED then
        if enable_chimes then play_sound(start_chime) end
        speak("Replay buffer started")
		
	 elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_STOPPED then
        if enable_chimes then play_sound(stop_chime) end
        speak("Replay buffer stopped")
		
	elseif event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
        if enable_ss then play_sound(screenshot_sound) end
    end
end

----------------------------------------------------------------------------
-- Called by OBS when the script is loaded
----------------------------------------------------------------------------
function script_load(settings)
    obs.obs_frontend_add_event_callback(on_event)
    init_tts()
end

----------------------------------------------------------------------------
-- Called by OBS when the script is unloaded
----------------------------------------------------------------------------
function script_unload()
    if voice then voice:Release(voice) end
    ole32.CoUninitialize()
end

function script_description()
    return [[
Plays .wav chimes and/or spoken announcements on:
  • start
  • stop
  • pause
  • resume

Plays screenshot sound.

Toggle sounds via the booleans at the top of this script.]]
end
