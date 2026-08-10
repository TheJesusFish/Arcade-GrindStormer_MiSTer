local machine = manager.machine
local debugger = assert(machine.debugger, "debugger is not enabled")
local audiocpu = assert(machine.devices[":audiocpu"], "missing :audiocpu")

debugger.visible_cpu = audiocpu
debugger:command("symlist")
for index = 1, #debugger.consolelog do
  print(debugger.consolelog[index])
end
emu.exit()
