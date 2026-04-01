from random import sample

from Read_AHS import find_field, get_bios, get_driver
from Read_AHS import get_cpu

def test_find_field_found():
    # fake data — we control it completely
    sample_lines = [
        "Product: HPE ProLiant DL380 Gen10\n",
        "Serial #: ABC123\n",
        "TPM Status: Present\n"
    ]
    result = find_field("Product:", sample_lines)
    assert result == "HPE ProLiant DL380 Gen10"

def test_find_field_missing():
    sample_lines = [
        "Product: HPE ProLiant DL380 Gen10\n",
    ]
    result = find_field("Secure Boot:", sample_lines)
    assert result == "[Manual]"

def test_get_cpu_dual():
    sample_lines = [
        # you fill these in
        "Version: AMD EPYC 7713 64-Core Processor\n",
        "Version: AMD EPYC 7713 64-Core Processor\n"
    ]
    cpu_name, cpu_qty = get_cpu(sample_lines)
    assert cpu_name == "AMD EPYC 7713 64-Core Processor"   # what name?
    assert cpu_qty == "2"    # what qty?

def test_get_cpu_single():
    sample_lines = [
        # you fill these in
        "Version: AMD EPYC 7713 64-Core Processor\n"
    ]
    cpu_name, cpu_qty = get_cpu(sample_lines)
    assert cpu_name == "AMD EPYC 7713 64-Core Processor"   # what name?
    assert cpu_qty == "1"    # what qty?

def test_get_cpu_missing():
    sample_lines = [
        "Product: HPE ProLiant DL380 Gen10\n"
    ]
    cpu_name, cpu_qty = get_cpu(sample_lines)
    assert cpu_name == "[MANUAL]"   # what name?
    assert cpu_qty == "[MANUAL]"    # what qty?

def test_get_bios():
    sample_lines = [
        "BIOS Version: A42\n",
        "System ROM v3.90 (10/03/2025)"
    ]

    result = get_bios(sample_lines)
    assert result == "A42 v3.90 (10/03/2025)"

def test_get_driver_found():
    sample_lines = [
        "ConnectX-6 Dx 100GE 2P NIC\n",
        "Driver: mlx5.sys, 25.7.26882.0\n"
    ]
    result = get_driver("ConnectX-6 Dx 100GE 2P NIC", sample_lines)
    assert result == "mlx5.sys, 25.7.26882.0"
        


def test_get_driver_missing():
    sample_lines = [
        "BIOS Version: A42\n",
    ]
    result = get_driver("ConnectX-6 Dx 100GE 2P NIC", sample_lines)
    assert result == "[MANUAL]"