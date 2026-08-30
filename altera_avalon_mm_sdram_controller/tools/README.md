# tools

| File | Purpose |
|---|---|
| `check_component.sh` | Verifies the Platform Designer component against a real Quartus installation |

## Why the component needs its own check

A `_hw.tcl` is a program, and every way it can fail is quiet:

* a malformed preset file leaves the Presets list silently empty
* a parameter of the wrong type reaches the HDL as something that is not a number
* a validation callback with a typo in it simply never fires

None of that shows up in simulation, because simulation never runs the
component description at all. Every one of those three happened while this
component was being written.

```bash
export QUARTUS_ROOT=/opt/intelFPGA/18.1
./check_component.sh          # 10 checks, no licence required
```

It builds a system, applies the preset, generates it, and inspects the
generated Verilog. The check that matters most is that **no parameter reaches
the HDL as a quoted string**: Platform Designer emits a FLOAT parameter as
`.T_RC_NS("60.0")`, and a string assigned to a `parameter real` is its ASCII
bytes read as a number — 60 ns arriving as 909127216.0, a 6-cycle tRC becoming
90 million. The controller takes integer picoseconds so this cannot happen, and
this check is what keeps it that way.
