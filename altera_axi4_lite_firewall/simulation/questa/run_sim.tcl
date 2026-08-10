# Note: After opening QuestaSim/Modelsim, change directory to this file's folder.

# Create and map working library
if {[file exists work]} { file delete -force work }
vlib work
vmap work work

# Compile Design, SVA, and Testbench with full coverage tracking
vlog -sv +acc +cover=sbceft ../../rtl/axi_firewall_regs.v
vlog -sv +acc +cover=sbceft ../../rtl/axi_firewall_top.v
vlog -sv +acc +cover=sbceft ../../tb/axi_firewall_sva.sv
vlog -sv +acc +cover=sbceft ../../tb/axi_firewall_tb.v

# Optimize design with assertion visibility and code coverage flags
vopt axi_firewall_tb -o tb_opt +acc -cover sbceft -assertdebug

# Execute simulation (GUI mode enabled)
vsim tb_opt -coverage -assertdebug
set NoQuitOnFinish 1
onbreak {resume}
run -all

# Save UCDB database and export reports
assertion report -verbose -recursive
coverage save coverage.ucdb

# -details (not -codeAll) so the report includes assertion results and cover
# directives as well as code coverage. -codeAll selects code coverage only and
# silently omits the SVA sections.
coverage report -details -output coverage_report.txt

puts "Simulation completed. Coverage saved to coverage.ucdb and coverage_report.txt"
# Comment out or remove this line to keep QuestaSim open:
# quit -f
