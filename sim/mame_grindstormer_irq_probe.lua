local machine = manager.machine
local debugger = assert(machine.debugger, "debugger is not enabled")
local maincpu = assert(machine.devices[":maincpu"], "missing :maincpu")
local screen = assert(machine.screens[":screen"], "missing :screen")
local output_path = os.getenv("GRINDSTORMER_IRQ_PROBE_OUTPUT") or
  "sim/generated/mame-main-irq-state.csv"
local exit_frame = tonumber(
  os.getenv("GRINDSTORMER_IRQ_PROBE_EXIT_FRAME") or "420")
local output = assert(io.open(output_path, "w"))
local finished = false
local last_screen_frame = -1

assert(maincpu.debug:bpset(
  0x0055e0,
  "",
  'logerror "DIRECT_55E0 frame=%d,totalcycles=%d,pc=%X,sr=%X",frame,totalcycles,pc,sr'))
assert(maincpu.debug:bpset(
  0x00562a,
  "",
  'logerror "DIRECT_562A frame=%d,totalcycles=%d,pc=%X,sr=%X",frame,totalcycles,pc,sr'))
assert(maincpu.debug:bpset(
  0x0002ce,
  "",
  'logerror "HANDLER_02CE frame=%d,totalcycles=%d,pc=%X,sr=%X",frame,totalcycles,pc,sr'))
debugger.visible_cpu = maincpu
debugger.execution_state = "run"

output:write("frame,screen_frame,master_cycle,pc,sr\n")
emu.register_frame_done(function()
  if finished then return end
  local screen_frame = screen:frame_number()
  local pc = maincpu.state["PC"].value & 0xffffff
  if screen_frame ~= last_screen_frame then
    last_screen_frame = screen_frame
    output:write(string.format(
      "%d,%d,%d,%06X,%04X\n",
      screen_frame + 1,
      screen_frame,
      math.floor(machine.time:as_double() * 94500000 + 0.5),
      pc,
      maincpu.state["SR"].value & 0xffff))
  end
  if screen_frame + 1 >= exit_frame and
      pc ~= 0x0055e2 and pc ~= 0x0002d0 then
    finished = true
    output:close()
    machine:exit()
  end
end)
