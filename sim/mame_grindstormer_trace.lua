local output_dir = os.getenv("GRINDSTORMER_TRACE_OUTPUT") or
  "sim/artifacts/mame-trace"
local exit_frame = tonumber(os.getenv("GRINDSTORMER_TRACE_EXIT_FRAME") or
  "7200")
local coin_frame = tonumber(os.getenv("GRINDSTORMER_TRACE_COIN_FRAME") or
  "600")
local start_frame = tonumber(os.getenv("GRINDSTORMER_TRACE_START_FRAME") or
  "660")
local control_frame = tonumber(
  os.getenv("GRINDSTORMER_TRACE_CONTROL_FRAME") or "780")
local snapshot_spec = os.getenv("GRINDSTORMER_TRACE_SNAPSHOTS") or
  "600,1200,1800,3600,6000"
local use_invulnerability =
  (os.getenv("GRINDSTORMER_TRACE_INVULNERABLE") or "1") ~= "0"

local machine = manager.machine
local screen = assert(machine.screens[":screen"], "missing :screen")
local maincpu = assert(machine.devices[":maincpu"], "missing :maincpu")
local audiocpu = assert(machine.devices[":audiocpu"], "missing :audiocpu")
local main_space = assert(maincpu.spaces["program"], "missing main space")
local audio_space = assert(audiocpu.spaces["program"], "missing audio space")
local vdp = assert(machine.devices[":gp9001"], "missing :gp9001")
local vdp_space = assert(vdp.spaces["gp9001vdp"], "missing GP9001 space")
local bus_trace = assert(io.open(output_dir .. "/bus-trace.csv", "w"))
local ym_trace = assert(io.open(output_dir .. "/ym-trace.csv", "w"))
local frame_trace = assert(io.open(output_dir .. "/frame-trace.csv", "w"))
local input_trace = assert(io.open(output_dir .. "/input-trace.csv", "w"))
local audio_metrics = assert(io.open(
  output_dir .. "/audio-metrics.csv", "w"))
local summary = assert(io.open(output_dir .. "/summary.txt", "w"))
local snapshot_frames = {}
local taps = {}
local scroll_select = 0xff
local scroll_regs = { 0, 0, 0, 0, 0, 0, 0, 0 }
local scroll_flip = 0

for token in string.gmatch(snapshot_spec, "[^,]+") do
  snapshot_frames[assert(tonumber(token), "invalid snapshot frame")] = true
end

local fields = {}
for _, port in pairs(machine.ioport.ports) do
  for _, field in pairs(port.fields) do
    fields[field.name] = field
  end
end

local function require_field(name)
  return assert(fields[name], "missing input field " .. name)
end

local controls = {
  coin = require_field("Coin 1"),
  start = require_field("1 Player Start"),
  up = require_field("P1 Up"),
  down = require_field("P1 Down"),
  left = require_field("P1 Left"),
  right = require_field("P1 Right"),
  button1 = require_field("P1 Button 1"),
  button2 = require_field("P1 Button 2")
}

if use_invulnerability then
  require_field("Invulnerability (Cheat)"):set_value(0x40)
end

local function set_control(field, pressed)
  if pressed then field:set_value(1) else field:clear_value() end
end

local function pulse(frame, first, period, duration)
  if frame < first then return false end
  return ((frame - first) % period) < duration
end

local function now_fields()
  local now = machine.time:as_double()
  return now, math.floor(now * 94500000 + 0.5)
end

local function main_pc()
  return maincpu.state["PC"].value & 0xffffff
end

local function audio_pc()
  return audiocpu.state["PC"].value & 0xfffff
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

local function dump_machine_state(frame)
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
end

bus_trace:write(
  "time_s,master_cycle,frame,source,address,data,mask,main_pc,audio_pc\n")
ym_trace:write(
  "time_s,master_cycle,frame,port,register,data,mask,audio_pc\n")
frame_trace:write(
  "frame,time_s,master_cycle,main_pc,audio_pc,vdp_count,shared_0000," ..
  "shared_7f00\n")
input_trace:write(
  "frame,time_s,coin,start,up,down,left,right,button1,button2\n")

local ym_register = 0
local ym_address_writes = 0
local ym_data_writes = 0
local main_shared_writes = 0
local audio_shared_writes = 0
local gp_writes = 0
local coin_writes = 0

local function log_bus(source, address, data, mask)
  local now, master_cycle = now_fields()
  bus_trace:write(string.format(
    "%.9f,%d,%d,%s,%06X,%04X,%04X,%06X,%05X\n",
    now, master_cycle, screen:frame_number(), source, address & 0xffffff,
    data & 0xffff, mask & 0xffff, main_pc(), audio_pc()))
end

taps[#taps + 1] = main_space:install_write_tap(
  0x20001c, 0x20001d, "grindstormer_coin_reset_trace",
  function(offset, data, mask)
    coin_writes = coin_writes + 1
    log_bus("main_coin_reset", 0x20001d, data, mask)
  end)

taps[#taps + 1] = main_space:install_write_tap(
  0x210000, 0x21ffff, "grindstormer_main_shared_trace",
  function(offset, data, mask)
    main_shared_writes = main_shared_writes + 1
    log_bus("main_shared", offset, data, mask)
  end)

taps[#taps + 1] = main_space:install_write_tap(
  0x300000, 0x30000f, "grindstormer_gp_trace",
  function(offset, data, mask)
    gp_writes = gp_writes + 1
    log_bus("gp9001", offset, data, mask)
    local port = offset & 0x0f
    if port == 0x08 or port == 0x0a then
      scroll_select = data & 0x8f
    elseif port == 0x0c or port == 0x0e then
      local register = scroll_select & 0x0f
      if register < 8 then
        scroll_regs[register + 1] = data & 0xffff
        local bit = 1 << register
        if (scroll_select & 0x80) ~= 0 then
          scroll_flip = scroll_flip | bit
        else
          scroll_flip = scroll_flip & (~bit)
        end
      end
    end
  end)

taps[#taps + 1] = audio_space:install_write_tap(
  0x00000, 0x00001, "grindstormer_ym_trace",
  function(offset, data, mask)
    local now, master_cycle = now_fields()
    local value = data & 0xff
    local port
    if (offset & 1) == 0 then
      ym_register = value
      ym_address_writes = ym_address_writes + 1
      port = "address"
    else
      ym_data_writes = ym_data_writes + 1
      port = "data"
    end
    ym_trace:write(string.format(
      "%.9f,%d,%d,%s,%02X,%02X,%02X,%05X\n",
      now, master_cycle, screen:frame_number(), port, ym_register, value,
      mask & 0xff, audio_pc()))
  end)

taps[#taps + 1] = audio_space:install_write_tap(
  0x80000, 0xfffff, "grindstormer_audio_shared_trace",
  function(offset, data, mask)
    audio_shared_writes = audio_shared_writes + 1
    log_bus("audio_shared", 0x80000 | (offset & 0x7fff), data, mask)
  end)

local hooked_tags = {}
for tag, sound in pairs(machine.sounds) do
  sound.hook = true
  hooked_tags[#hooked_tags + 1] = tag
end
table.sort(hooked_tags)

local stats = {}
local function add_sample(second, stream, value)
  local key = string.format("%d,%s", second, stream)
  local row = stats[key]
  if row == nil then
    row = {
      second = second, stream = stream, count = 0,
      sum = 0.0, sumsq = 0.0, peak = 0.0
    }
    stats[key] = row
  end
  local magnitude = math.abs(value)
  row.count = row.count + 1
  row.sum = row.sum + value
  row.sumsq = row.sumsq + value * value
  if magnitude > row.peak then row.peak = magnitude end
end

emu.register_sound_update(function(samples)
  local second = math.floor(machine.time:as_double())
  for tag, channels in pairs(samples) do
    for channel_index, channel in ipairs(channels) do
      for _, value in ipairs(channel) do
        add_sample(second,
          string.format("%s.ch%d", tag, channel_index - 1), value)
      end
    end
  end
end)

local function write_audio_metrics()
  audio_metrics:write(
    "second,stream,count,mean,rms,peak,rms_dbfs,peak_dbfs\n")
  local rows = {}
  for _, row in pairs(stats) do rows[#rows + 1] = row end
  table.sort(rows, function(left, right)
    if left.second == right.second then return left.stream < right.stream end
    return left.second < right.second
  end)
  for _, row in ipairs(rows) do
    local mean = row.sum / row.count
    local rms = math.sqrt(row.sumsq / row.count)
    local rms_db = rms > 0 and 20 * math.log(rms, 10) or -200
    local peak_db = row.peak > 0 and
      20 * math.log(row.peak, 10) or -200
    audio_metrics:write(string.format(
      "%d,%s,%d,%.12g,%.12g,%.12g,%.6f,%.6f\n",
      row.second, row.stream, row.count, mean, rms, row.peak,
      rms_db, peak_db))
  end
end

local frame = 0
local finished = false
emu.register_frame_done(function()
  if finished then return end
  local _keep_taps_alive = #taps
  frame = frame + 1

  local coin = frame >= coin_frame and frame < coin_frame + 4
  local start = frame >= start_frame and frame < start_frame + 4
  local active = frame >= control_frame
  local phase = active and (((frame - control_frame) // 120) % 8) or 0
  local up = active and (phase == 0 or phase == 1 or phase == 7)
  local right = active and (phase == 1 or phase == 2 or phase == 3)
  local down = active and (phase == 3 or phase == 4 or phase == 5)
  local left = active and (phase == 5 or phase == 6 or phase == 7)
  local button1 = active and ((frame - control_frame) % 240) < 228
  local button2 = pulse(frame, control_frame + 120, 480, 3)

  set_control(controls.coin, coin)
  set_control(controls.start, start)
  set_control(controls.up, up)
  set_control(controls.down, down)
  set_control(controls.left, left)
  set_control(controls.right, right)
  set_control(controls.button1, button1)
  set_control(controls.button2, button2)

  local now, master_cycle = now_fields()
  input_trace:write(string.format(
    "%d,%.9f,%d,%d,%d,%d,%d,%d,%d,%d\n",
    frame, now, coin and 1 or 0, start and 1 or 0,
    up and 1 or 0, down and 1 or 0, left and 1 or 0,
    right and 1 or 0, button1 and 1 or 0, button2 and 1 or 0))

  local vdp_count = main_space:read_u16(0x700000) & 0xffff
  local shared_0000 = main_space:read_u8(0x210001) & 0xff
  local shared_7f00 = main_space:read_u8(0x21fe01) & 0xff
  frame_trace:write(string.format(
    "%d,%.9f,%d,%06X,%05X,%04X,%02X,%02X\n",
    frame, now, master_cycle, main_pc(), audio_pc(), vdp_count,
    shared_0000, shared_7f00))

  if snapshot_frames[frame] then
    dump_machine_state(frame)
    screen:snapshot(string.format(
      "%s/frame-%06d.png", output_dir, frame))
  end

  if frame >= exit_frame then
    finished = true
    write_audio_metrics()
    summary:write(string.format("frames=%d\n", frame))
    summary:write(string.format("main_shared_writes=%d\n", main_shared_writes))
    summary:write(string.format(
      "audio_shared_writes=%d\n", audio_shared_writes))
    summary:write(string.format("gp_writes=%d\n", gp_writes))
    summary:write(string.format("coin_reset_writes=%d\n", coin_writes))
    summary:write(string.format("ym_address_writes=%d\n", ym_address_writes))
    summary:write(string.format("ym_data_writes=%d\n", ym_data_writes))
    summary:write(string.format("final_main_pc=%06X\n", main_pc()))
    summary:write(string.format("final_audio_pc=%05X\n", audio_pc()))
    summary:write(string.format(
      "invulnerability=%d\n", use_invulnerability and 1 or 0))
    summary:write("hooked_sound_tags=" .. table.concat(hooked_tags, ",") .. "\n")
    bus_trace:close()
    ym_trace:close()
    frame_trace:close()
    input_trace:close()
    audio_metrics:close()
    summary:close()
    for _, tap in ipairs(taps) do tap:remove() end
    machine:exit()
  end
end)
