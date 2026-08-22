# altera-ip-cores
This is just a collection of common cores, that can be added/used to a Quartus projects as an ip component in Platform Designer (Qsys).
In order to make those ip cores available in Quartus Platform Designer, add the top-level directory (altera-ip-core) to generate the Qsys. Go to Platform Designer (QSYS) window -> select Tools -> Options -> in "IP Search Path" -> Add... -> the 'altera-ip- core' full directory which you had cloned.

Note: You may also need to add to the IP search path - the '../altera_axi4_lite_firewall/example/', in order to get the AXI4-Lite Firewall examples to open and work properly in Quartus/Qsys.
