from scapy.all import sendp, Ether, IP, UDP

destination_ip = '255.255.255.255'
source_ip = '192.168.1.1'
source_mac = '52:54:00:ac:05:8c'
destination_mac = '52:54:00:ac:05:8c' 
source_port = 14236
destination_port = 14235

packet = Ether(src=source_mac, dst=destination_mac) / IP(src=source_ip, dst=destination_ip) / UDP(sport=source_port, dport=destination_port)

sendp(packet)
