#!/bin/bash

OUTPUT_FILE="linkwidth_report.txt"

echo "=======================================" | tee $OUTPUT_FILE
echo "   PCIe Link Width Auto Test Script     " | tee -a $OUTPUT_FILE
echo "=======================================" | tee -a $OUTPUT_FILE
echo "" | tee -a $OUTPUT_FILE

# STEP 1: Find all Ethernet devices (same as: lspci | grep Ethernet)
echo "Detecting Ethernet Controllers..." | tee -a $OUTPUT_FILE
ETH_DEVS=$(lspci | grep -i ethernet)

if [ -z "$ETH_DEVS" ]; then
    echo "No Ethernet controller detected!" | tee -a $OUTPUT_FILE
    exit 1
fi

echo "$ETH_DEVS" | tee -a $OUTPUT_FILE
echo "" | tee -a $OUTPUT_FILE

# STEP 2: Extract Bus IDs automatically (c6:00.0 etc.)
BUS_IDS=$(echo "$ETH_DEVS" | awk '{print $1}')

echo "Detected Bus IDs:"
echo "$BUS_IDS" | tee -a $OUTPUT_FILE
echo "" | tee -a $OUTPUT_FILE

# STEP 3: Save full lspci -vvv output to file (same as ppt step)
echo "Dumping full PCI info to abc.txt ..."
lspci -vvv > abc.txt
echo "File created: abc.txt" | tee -a $OUTPUT_FILE
echo "" | tee -a $OUTPUT_FILE

# STEP 4: Parse Link Width for each Bus ID
echo "=======================================" | tee -a $OUTPUT_FILE
echo "        PCIe LINK WIDTH RESULTS         " | tee -a $OUTPUT_FILE
echo "=======================================" | tee -a $OUTPUT_FILE

for BUS in $BUS_IDS; do
    echo "" | tee -a $OUTPUT_FILE
    echo "Checking BUS: $BUS" | tee -a $OUTPUT_FILE

    # Extract the block for this bus ID
    INFO=$(lspci -s $BUS -vvv)

    # Look for link width fields
    CURRENT_WIDTH=$(echo "$INFO" | grep -i "LnkSta:" | grep -o "Width x[0-9]\+" | awk '{print $2}')
    MAX_WIDTH=$(echo "$INFO" | grep -i "LnkCap:" | grep -o "Width x[0-9]\+" | awk '{print $2}')

    if [ -z "$CURRENT_WIDTH" ]; then
        echo "Unable to detect link width for $BUS" | tee -a $OUTPUT_FILE
    else
        echo "Current Link Width: $CURRENT_WIDTH" | tee -a $OUTPUT_FILE
        echo "Maximum Supported:  $MAX_WIDTH" | tee -a $OUTPUT_FILE
    fi
done

echo "" | tee -a $OUTPUT_FILE
echo "Test Completed. Detailed log saved in: linkwidth_report.txt"
echo "Raw PCI dump saved in: abc.txt"
