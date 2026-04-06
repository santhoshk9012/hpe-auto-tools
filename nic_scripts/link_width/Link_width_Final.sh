#!/bin/bash

OUTPUT="linkwidth_report.txt"
rm -f $OUTPUT abc.txt

echo "========================================" | tee -a $OUTPUT
echo "   PCIe LINK WIDTH – AUTO TEST SUITE    " | tee -a $OUTPUT
echo "========================================" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# STEP 1 — List all Ethernet controllers
echo "Detecting Ethernet devices..." | tee -a $OUTPUT
ETH_LIST=$(lspci -D | grep -i ethernet)

if [ -z "$ETH_LIST" ]; then
    echo "No Ethernet controllers found!" | tee -a $OUTPUT
    exit 1
fi

echo "$ETH_LIST" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# Extract Bus IDs like 0000:c6:00.0
BUS_IDS=$(echo "$ETH_LIST" | awk '{print $1}')

echo "Bus IDs:" | tee -a $OUTPUT
echo "$BUS_IDS" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

# STEP 2 — Dump full PCI info
echo "Creating abc.txt dump..."
lspci -vvv > abc.txt
echo "Saved to abc.txt" | tee -a $OUTPUT
echo "" | tee -a $OUTPUT

echo "========================================" | tee -a $OUTPUT
echo "          PCIe DEVICE DETAILS           " | tee -a $OUTPUT
echo "========================================" | tee -a $OUTPUT

for BUS in $BUS_IDS; do
    echo "" | tee -a $OUTPUT
    echo "Checking device at BUS $BUS" | tee -a $OUTPUT
    
    INFO=$(lspci -s $BUS -vvv)
    
    # Extract card model
    CARD_MODEL=$(echo "$INFO" | head -1 | cut -d':' -f3- | sed 's/^[ \t]*//')
    
    # Extract physical slot
    SLOT=$(echo "$INFO" | grep -i "Physical Slot" | awk -F': ' '{print $2}')
    SLOT=${SLOT:-Unknown}

    # Extract link width (OS level)
    CURRENT_WIDTH=$(echo "$INFO" | grep -i "LnkSta:" | grep -o "Width x[0-9]\+" | awk '{print $2}')
    MAX_WIDTH=$(echo "$INFO" | grep -i "LnkCap:" | grep -o "Width x[0-9]\+" | awk '{print $2}')

    echo "   • Card Model:        $CARD_MODEL" | tee -a $OUTPUT
    echo "   • Slot Number:       $SLOT" | tee -a $OUTPUT
    echo "   • Current Width:     ${CURRENT_WIDTH:-Unknown}" | tee -a $OUTPUT
    echo "   • Max Supported:     ${MAX_WIDTH:-Unknown}" | tee -a $OUTPUT

    # ===============================
    # NEW FEATURE: NETWORK LINK STATUS
    # ===============================

    SYS_PATH="/sys/bus/pci/devices/${BUS}/net"

    if [ -d "$SYS_PATH" ]; then
        IFACES=$(ls $SYS_PATH)

        for IFACE in $IFACES; do
            OPERSTATE=$(cat /sys/class/net/$IFACE/operstate 2>/dev/null)
            SPEED=$(cat /sys/class/net/$IFACE/speed 2>/dev/null)

            if [[ "$OPERSTATE" == "up" ]]; then
                if [[ "$SPEED" =~ ^[0-9]+$ ]]; then
                    echo "   • Network Link:      UP (${SPEED} Mbps)  [${IFACE}]" | tee -a $OUTPUT
                else
                    echo "   • Network Link:      UP (Speed Unknown) [${IFACE}]" | tee -a $OUTPUT
                fi
            elif [[ "$OPERSTATE" == "down" ]]; then
                echo "   • Network Link:      DOWN [${IFACE}]" | tee -a $OUTPUT
            else
                echo "   • Network Link:      UNKNOWN [${IFACE}]" | tee -a $OUTPUT
            fi
        done
    else
        echo "   • Network Link:      No interface mapped to this PCI device" | tee -a $OUTPUT
    fi

    echo "   Compare slot & link width manually with RBSU" | tee -a $OUTPUT
done

echo "" | tee -a $OUTPUT
echo "Test complete. Detailed report saved in: $OUTPUT"
echo "Full PCI dump: abc.txt"
``