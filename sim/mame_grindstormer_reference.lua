local frame_spec = os.getenv("GRINDSTORMER_REFERENCE_FRAMES") or
  "599,600,601,1199,1200,1201,1799,1800,1801"
local output_dir = os.getenv("GRINDSTORMER_REFERENCE_OUTPUT") or
  "sim/artifacts/mame-reference"
local manifest_path = output_dir .. "/manifest.txt"

local machine = manager.machine
local screen = assert(machine.screens[":screen"], "missing :screen")
local maincpu = assert(machine.devices[":maincpu"], "missing :maincpu")
local audiocpu = assert(machine.devices[":audiocpu"], "missing :audiocpu")
local main_space = assert(maincpu.spaces["program"], "missing main space")
local vdp = assert(machine.devices[":gp9001"], "missing :gp9001")
local vdp_space = assert(vdp.spaces["gp9001vdp"], "missing GP9001 space")
local capture_frames = {}
local ordered_frames = {}
local last_frame = 0
local scroll_select = 0xff
local scroll_regs = { 0, 0, 0, 0, 0, 0, 0, 0 }
local scroll_flip = 0
local manifest = assert(io.open(manifest_path, "w"))

for token in string.gmatch(frame_spec, "[^,]+") do
  local frame = assert(tonumber(token), "invalid reference frame")
  capture_frames[frame] = true
  ordered_frames[#ordered_frames + 1] = frame
  if frame > last_frame then last_frame = frame end
end

local function dump_words(path, count, read_word)
  local output = assert(io.open(path, "w"))
  for index = 0, count - 1 do
    output:write(string.format("%04x\n", read_word(index) & 0xffff))
  end
  output:close()
end

local function dump_bytes(path, count, read_byte)
  local output = assert(io.open(path, "w"))
  for index = 0, count - 1 do
    output:write(string.format("%02x\n", read_byte(index) & 0xff))
  end
  output:close()
end

local function dump_frame(frame)
  dump_words(
    string.format("%s/gp9001-frame-%06d.hex", output_dir, frame),
    8192,
    function(index) return vdp_space:read_u16(index * 2) end)

  dump_words(
    string.format("%s/palette-frame-%06d.hex", output_dir, frame),
    2048,
    function(index) return main_space:read_u16(0x400000 + index * 2) end)

  dump_words(
    string.format("%s/work-frame-%06d.hex", output_dir, frame),
    8192,
    function(index) return main_space:read_u16(0x100000 + index * 2) end)

  dump_bytes(
    string.format("%s/shared-frame-%06d.hex", output_dir, frame),
    32768,
    function(index) return main_space:read_u8(0x210001 + index * 2) end)

  local scroll_output = assert(io.open(string.format(
    "%s/scroll-frame-%06d.hex", output_dir, frame), "w"))
  for register = 1, 8 do
    scroll_output:write(string.format("%04x\n", scroll_regs[register]))
  end
  scroll_output:write(string.format("%04x\n", scroll_flip))
  scroll_output:close()

  local main_pc = maincpu.state["PC"].value & 0xffffff
  local audio_pc = audiocpu.state["PC"].value & 0xfffff
  manifest:write(string.format(
    "frame=%d screen=%d main_pc=%06x audio_pc=%05x\n",
    frame, screen:frame_number(), main_pc, audio_pc))
  manifest:flush()
  screen:snapshot(string.format(
    "%s/frame-%06d.png", output_dir, frame))
end

local scroll_tap = main_space:install_write_tap(
  0x300000, 0x30000f, "grindstormer_reference_scroll",
  function(offset, data)
    local port = offset & 0x0f
    if port == 0x08 or port == 0x0a then
      scroll_select = data & 0x8f
    elseif port == 0x0c or port == 0x0e then
      local register = scroll_select & 0x0f
      if register < 8 then
        scroll_regs[register + 1] = data & 0xffff
        local mask = 1 << register
        if (scroll_select & 0x80) ~= 0 then
          scroll_flip = scroll_flip | mask
        else
          scroll_flip = scroll_flip & (~mask)
        end
      end
    end
  end)

manifest:write("frames=" .. table.concat(ordered_frames, ",") .. "\n")
manifest:flush()

local frame = 0
local captured = 0
emu.register_frame_done(function()
  local _keep_tap_alive = scroll_tap
  frame = frame + 1
  if capture_frames[frame] then
    dump_frame(frame)
    captured = captured + 1
  end
  if frame > last_frame then
    manifest:write(string.format(
      "complete frames=%d captures=%d\n", frame, captured))
    manifest:close()
    scroll_tap:remove()
    machine:exit()
  end
end)
