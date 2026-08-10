local output_path = os.getenv("GRINDSTORMER_V25_TRACE_OUTPUT") or
  "sim/generated/mame-v25-instructions.log"
local exit_frame = tonumber(
  os.getenv("GRINDSTORMER_V25_TRACE_EXIT_FRAME") or "90")

local machine = manager.machine
local debugger = assert(machine.debugger, "debugger is not enabled")
local audiocpu = assert(machine.devices[":audiocpu"], "missing :audiocpu")
local screen = assert(machine.screens[":screen"], "missing :screen")
local trace_path = string.gsub(output_path, "\\", "/")
local frame = 0
local finished = false

debugger.visible_cpu = audiocpu
debugger:command(string.format(
  'trace "%s",:audiocpu,noloop,{tracelog "TC=%%d,IC=%%d,",totalcycles,lastinstructioncycles}',
  trace_path))
debugger.execution_state = "run"

emu.register_frame_done(function()
  if finished then return end
  frame = frame + 1
  if frame >= exit_frame then
    finished = true
    debugger:command("trace off,:audiocpu")
    debugger:command("traceflush")
    print(string.format(
      "V25 instruction trace complete frames=%d screen_frame=%d path=%s",
      frame, screen:frame_number(), trace_path))
    machine:exit()
  end
end)
