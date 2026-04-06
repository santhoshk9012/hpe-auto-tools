import sys
import os

# Simple field extractor
def find_field(keyword, lines):
    for line in lines:
        if keyword in line:
            parts = line.strip().split(":",1)
            if len(parts) >= 2:
                return parts[1].strip()
    return "[Manual]"
def get_cpld(lines):
        for line in lines:
            if "System Programmable Logic Device" in line and "0x" in line:
                return line.strip().split()[-1]
        return "[MANUAL]"

def get_os(lines):
        for line in lines:
            if "Operating System" in line and "OK" in line:
                return line.strip().split("Operating System")[1].strip()
        return "[MANUAL]"

# BIOS version handling
def get_bios(lines):
    family = "[MANUAL]"
    version = "[MANUAL]"

    for line in lines:
        if "BIOS Version:" in line:
            family = line.strip().split(":")[1].strip()

        if "System ROM" in line and "v" in line and "Redundant" not in line:
            version = line.strip().split("System ROM")[1].strip()
    if family in version:
        return version
    return f"{family} {version}"

    if family != "[MANUAL]" and version != "[MANUAL]":
        return f"{family} {version}"
    return "[MANUAL]"

def get_cpu(lines):
    cpu_name = []
    cpu_qty = 0
    for line in lines:
        if "Version:" in line and ("Intel" in line  or "AMD" in line or "INTEL" in line):
            name = line.strip().split("Version:")[1].strip()
            if name not in cpu_name:
                cpu_name.append(name)
            cpu_qty += 1

    if cpu_qty > 0:
        return ",".join(cpu_name), str(cpu_qty)   
    return "[MANUAL]", "[MANUAL]"


#NICs
def get_nics(lines):
    nics = []
    current = {}
    in_networking = False 
    for line in lines:
        stripped = line.strip()
        if "Networking Dashboard" in line:
            in_networking = True

        if not in_networking:
            continue

        if "Power Dashboard" in line:
            break    

        if "Product:" in line and "Power" not in line: 
            if current:
                nics.append(current)
            current = {"name": stripped.split("Product:")[1].strip()}
        elif "Slot #:" in stripped and current:
            current["slot"] = stripped.split("Slot #:")[1].strip()
        elif "Firmware Version:" in stripped and current:
            current["fw"] = stripped.split("Firmware Version:")[1].strip()
    if current:
        nics.append(current)
    return nics            

#NIC Driver
def get_driver(nic_name, lines):
    found = False

    for line in lines:
        if nic_name in line:
            found =True

        if found and "Driver:" in line:
            return line.strip().split("Driver:")[1].strip()
    return "[MANUAL]"

#Memory
def get_memory(lines):
    memory = []
    current = {}
    in_physical_memory = False

    for line in lines:
        if "Physical Memory" in line and line.strip() == "Physical Memory":
            in_physical_memory = True

        if "Networking Dashboard" in line and in_physical_memory:
            break
        
        if not in_physical_memory:
            continue

        if "Location:" in line:
            if current:
                memory.append(current)
            current ={"location": line.strip().split("Location:")[1].strip()}
        elif "Size:" in line and current and "PROC" in current.get("location", ""):
            current["size"] = line.strip().split("Size:")[1].strip()

    if current:
        memory.append(current)
    return memory


if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="HPE AHS Parser Tool")
    parser.add_argument("--file", required=True)
    parser.add_argument("--output", default="HW_Config_Report.txt")
    args = parser.parse_args()

    if not os.path.exists(args.file):
        print(f"Error: File '{args.file}' not found.")
        sys.exit(1)

    with open(args.file, "r") as file:
        lines = file.readlines()

    cpu_name, cpu_qty = get_cpu(lines)
    nics = get_nics(lines)
    memory = get_memory(lines)
    for nic in nics:
        nic["driver"] = get_driver(nic["name"], lines)

    memory_str = ""
    for slot in memory:
        memory_str += f"\n        {slot.get('location','[MANUAL]')}  {slot.get('size','')}"

    report = f"""
Hardware Configuration
* Server Type     : {find_field("Product:", lines)}
* ROM Family & ver: {get_bios(lines)}
* OS Version      : {get_os(lines)}
* Build Type      : [MANUAL]-DP, VP, DSPB, DMVB, Production
* OS Installed on : [MANUAL]-HDD/BFS
* Secure Boot     : [MANUAL]-Enabled/disabled
* Boot Mode       : [MANUAL]-UEFI/legacy
* iLO Version     : {find_field("Version: iLO", lines)}
* CPLD Version    : {get_cpld(lines)}
* CPU Family      : {cpu_name}
* CPU Qty         : {cpu_qty}
* Memory Type & Total RAM:{memory_str}

[NIC/CNA]"""

    for nic in nics:
        report += f"""
* NIC Type : {nic.get("name", "[MANUAL]")}
  Slot     : {nic.get("slot", "[MANUAL]")}
  FW Ver   : {nic.get("fw", "[MANUAL]")}
  Driver   : {nic.get("driver", "[MANUAL]")}"""

    with open(args.output, "w") as f:
        f.write(report)

    print("Report generated successfully!")
    print(report)
