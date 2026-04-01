my_server = {
    "name": "dl380",
    "ip": "172.18.69.79",
    "status": "active"
}
print(my_server["ip"])

my_server["owner"]="santhosh"
print(my_server)

servers = ["dl380","dl360","dl325","alletra4002"]
for server in servers:
    print("checking server:", server)

servers=[
    {"name":"dl380", "ip":"172.18","status": "active"},
    {"name":"dl360", "ip":"172.17","status": "offline"},
    {"name":"dl325", "ip":"172.16","status": "active"},
    {"name":"alletra4002","ip":"172.15","status":"offline"}
]

for server in servers:
    if server["status"]== "active":
        print(server["name"],"is UP")
    else:
        print(server['name'], "is Down")
   #print(server["name"],"-->",server["ip"],"-->", server["status"])


def check_server(server):
    if server["status"]== "active":
        print(server["name"],"is UP")
    else:
        print(server['name'], "is Down")

for server in servers:
    check_server(server)

def check_server(server):
    if server["status"]=="active":
        return "UP"
    else:
        return "Down"
servers=[
    {"name":"dl380", "ip":"172.18","status": "active"},
    {"name":"dl360", "ip":"172.17","status": "offline"},
    {"name":"dl325", "ip":"172.16","status": "active"},
    {"name":"alletra4002","ip":"172.15","status":"offline"}
]
down_servers=[]
count=0
for server in servers:
    result = check_server(server)
    if result =="Down":
        count +=1
        down_servers.append(server["name"])

print("server needs attention:", down_servers)

print("Total servers down:", count)
