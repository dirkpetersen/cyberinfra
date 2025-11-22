# Weka.io

The purpose of this Weka.io cluster is to provide multi-protocol file access to users of an AI supercomputer 

Hardware:

- Check hardware-sample-bom-weka-supermicro.csv for hardware details 
- 9 Weka.io hosts 
- Boot drives for each host are 2 Samsung PM9A3 960GB NVMe PCIe4x4 M.2 22x110mm 1DWPD SED 5YR
- each host has 6 x Samsung PM1743 15.3T NVMePCIeGen5 E3.S 1T 1DWPD 5YR SED to be used for data 
- each host has a 1G mgmt port for ipmi redfish which is conencted to a dedicated switch network 
- each host has a dual 25G NIC which we are planning to bind to NFS and SMB services in a separate enterprise VLAN
- each host has two dual MCX653106A-HDAT, CX-6 VPI,HDR,200GbE,2p,QSFP56,PCIe4x16 (so a total of 4 per node)
- one CX-6 200G pair is connected to a pair of redundant HPE 5960 400G switches (configured as EVPN/VXLAN environment. In that environment you can do “ESI” based MC-LAG 

Network config

- one CX-6 200G pair is connected to a pair of redundant HPE 5960 400G switches (configured as EVPN/VXLAN environment. In that environment you can do “ESI” based MC-LAG 
- eventually needs 2-3 different VLANS per 200G NIC 
- the second pair of CX-6 200G will be connected directly to the supercomputer network, possibly via IB 
- right now we reserved a separate VLAN for weka internal traffic but is this even supported ?
- I have allocated one ip address per 2 nivs as expect NIC bonding, but is that even a thing with weka 

Devops: 

- using Ansible, playbooks in public github while parameters (IPs hostnames) with be in AWS Systems Manager (SSM) Parameter Store. Ansible has a built-in aws_ssm lookup plugin which can pull parameters into playbooks at runtime.

Weka Documentation:  

- please check subfolder/symlink docs-weak-io for details, make sure you ingest the entire documentation !