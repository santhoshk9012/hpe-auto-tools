# HPE AHS Hardware Config Parser

A Python CLI tool that automatically parses HPE Active Health 
System (AHS) summary files and generates hardware config reports.

## Features
- Extracts 10+ hardware fields automatically
- Handles multiple server platforms (Gen10/Gen11/Gen12)
- 8 automated pytest tests
- GitHub Actions CI pipeline

## Usage
python Read_AHS.py --file AHS_Summary.txt
python Read_AHS.py --file AHS_Summary.txt --output report.txt

## Tech Stack
Python · pytest · GitHub Actions · argparse
