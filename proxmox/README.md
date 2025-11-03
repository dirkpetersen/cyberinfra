# Proxmox 

The purpose of this Proxmox cluster is to provide infrastructure VMs and LXC containers to different VLANS, some of these VMs are gateways systems that bridge different vlans 

Hardware:

- Check hardware-sample-bom-supermicro.csv for hardware details 
- 3 Proxmox hosts 
- Boot drives for each host are Micron 7450 PRO 480GB NVMe PCIe 4.0 M.2 22x80mm 3D TLC, should be mirrored using proxmox 
- each host has 12 SSD 2.5" NVMe PCIe5 7.68TB 1DWPD TLC D, SIE/ISE, 15mm#(CQ8601248067) which will be configured as replicated ceph flash pool or as one ZFS draid pool per host 
- each host will mount a weka file system which will cappy most of the VMs and LXC containers 
- each host has a 1G mgmt port for ipmi redfish which is conencted t a dedicated switch network 
- each host has a dual 25G NIC which we were not planning to use (AIOM 2-port 25GbE SFP28,Mellanox CX-6 )
- each host has dual MCX653106A-HDAT, CX-6 VPI,HDR,200GbE,2p,QSFP56,PCIe4x16 with multiple VLANs configured 
- each CX-6 200G pair is connected to a pair of redundant HPE 5960 400G switches (configured as EVPN/VXLAN environment. In that environment you can do “ESI” based MC-LAG 
- each host has a single A16 GPU and we want to use MIC and the nvidia vcpu software to flexibily share these GPU with LXC containers as well as with 
- needs 5 different VLANS to which only VMs and LXC containers should be bound and one isolated VLAN that is bound to the host OS, this vlan is only accessible only by sysadmins

Devops: 

- using Ansible, playbooks in public github while parameters (IPs hostnames) with be in AWS Systems Manager (SSM) Parameter Store. Ansible has a built-in aws_ssm lookup plugin which can pull parameters into playbooks at runtime.