import json
import os

os.chdir(os.path.dirname(os.path.abspath(__file__)))


with open("servers.json", "r") as file:
    servers = json.load(file)

def check_server(server):
    if server["status"] == "active":
        return "UP"
    else:
        return "DOWN"
    
down_servers = []

for server in servers:
    result = check_server(server)
    if result == "DOWN":
        down_servers.append(server["name"])

print("servers need attention:", down_servers)
print("count of servers down:", len(down_servers))
