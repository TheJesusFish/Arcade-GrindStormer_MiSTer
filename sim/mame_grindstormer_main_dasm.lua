local machine = manager.machine
local debugger = assert(machine.debugger, "debugger is not enabled")
local maincpu = assert(machine.devices[":maincpu"], "missing :maincpu")

debugger.visible_cpu = maincpu
debugger:command(
  'dasm "sim/generated/mame-main-dasm-isr.txt",0x000200,0x000600')
debugger:command(
  'dasm "sim/generated/mame-main-dasm-loop.txt",0x005400,0x000600')
debugger:command(
  'dasm "sim/generated/mame-main-dasm-init.txt",0x008800,0x000200')
debugger:command(
  'dasm "sim/generated/mame-main-dasm-boot.txt",0x020700,0x000500')
machine:exit()
