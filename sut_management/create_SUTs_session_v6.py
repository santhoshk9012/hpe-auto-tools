import argparse
import logging
import os
import platform
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import requests
import urllib3
import shutil

# ============================================================
# Colored Logging
# ============================================================
try:
    import colorama
    colorama.init(convert=True, autoreset=True)
except ImportError:
    pass

class ColorFormatter(logging.Formatter):
    COLORS = {
        "DEBUG": "\033[37m",
        "INFO": "\033[36m",
        "WARNING": "\033[33m",
        "ERROR": "\033[31m",
        "CRITICAL": "\033[41m",
    }
    RESET = "\033[0m"

    def format(self, record):
        color = self.COLORS.get(record.levelname, self.RESET)
        return f"{color}{super().format(record)}{self.RESET}"


_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(ColorFormatter("%(asctime)s %(levelname)-8s %(message)s", "%Y-%m-%d %H:%M:%S"))
log = logging.getLogger(__name__)
log.setLevel(logging.INFO)
log.handlers.clear()
log.addHandler(_handler)

# ============================================================
# Config
# ============================================================
BB_TOKEN = os.environ.get("BB_TOKEN", "ba75d231779b40ee6b36b835f61e6158")
SUT_PASSWORD_DEFAULT = os.environ.get("SUT_PASSWORD_DEFAULT", "nspauto@123")
SUT_PASSWORD_NYE = os.environ.get("SUT_PASSWORD_NYE", "admin123")
BB_BASE = "https://bluebird.tw.hpecorp.net/api/suts/"

MEMBER_EMAILS = [
    "nyen@hpe.com",
    "alex.chu@hpe.com",
    "jeffrey.lee@hpe.com",
    "santhosh.k@hpe.com",
    "dean.hou@hpe.com",
    "billy.yao@hpe.com",
    "ipsita.nayak@hpe.com",
    "sai-ram-anudeep.padala@hpe.com",
    "soumya.tipparam@hpe.com",
    "saisagar.sudhir@hpe.com",
]

IUR_PASSWORD_EXCEPTIONS = {
    "VPR095-P03-01U": SUT_PASSWORD_DEFAULT,
    "VPR076-P07-32U-9FN": SUT_PASSWORD_NYE,
}

EXCLUDE_IURS = {
    "VPR038-P10-32U",
    "VPR102-P08-35U",
    "VPR029-P04-10U",
    "VPR076-P01-01U-9FN",
}

EXCEPTION_IPS = [
    ("172.18.189.157", "VPR105-P05-24U-1-9FN(477850)", "EL140 Gen12"),
]

ACTIVE_COLS = ["email", "name", "product_name", "ilo_connect_status", "ilo_ip", "active_end_time", "result"]
BOOKED_COLS = ["email", "name", "product_name", "ilo_connect_status", "ilo_ip"]
LOW_COLS = ["email", "name", "product_name", "ilo_connect_status", "ilo_ip", "active_end_time"]
RESULT_COLS = ["email", "name", "product_name", "ilo_ip", "active_end_time", "result"]

# Color for result
_RESULT_COLORS = {
    "session created": "\033[32m",
    "timeout": "\033[33m",
    "not pingable": "\033[31m",
    "session failed": "\033[31m",
}
_RESET = "\033[0m"
_CYAN = "\033[36m"


def _color_result(text: str) -> str:
    t = str(text).lower()
    for key, color in _RESULT_COLORS.items():
        if key in t:
            return f"{color}{text}{_RESET}"
    return f"{_CYAN}{text}{_RESET}"


# ============================================================
# SECTION HEADER (Centered)
# ============================================================
def section(title: str):
    # Colors
    COLOR_TITLE = "\033[35m"      
    COLOR_BAR = "\033[90m"        # Bright gray
    RESET = "\033[0m"

    width = 140  # fixed width for clean layout
    bar = COLOR_BAR + ("=" * width) + RESET

    title_fmt = f"{COLOR_TITLE} {title} {RESET}"
    pad_left = (width - len(title) - 2) // 2
    pad_right = width - pad_left - len(title) - 2

    log.info(bar)
    log.info(" " * pad_left + title_fmt + " " * pad_right)
    log.info(bar)




# ============================================================
# TABLE PRINTER (Clean, Box-Drawing)
# ============================================================
def print_SUTs_info(suts: list, columns: list = None, title: str = None):
    if title:
        log.info(title)
    if not suts:
        log.info(" (No IUR's Found)")
        return

    cols = columns or list(suts[0].keys())

    widths = {c: max(len(c), *(len(str(s.get(c, ""))) for s in suts)) for c in cols}

    border_top = "┌" + "┬".join("─" * (widths[c] + 2) for c in cols) + "┐"
    border_mid = "├" + "┼".join("─" * (widths[c] + 2) for c in cols) + "┤"
    border_bot = "└" + "┴".join("─" * (widths[c] + 2) for c in cols) + "┘"

    log.info(border_top)

    header = "│" + "│".join(f" {c:<{widths[c]}} " for c in cols) + "│"
    log.info(header)
    log.info(border_mid)

    for s in suts:
        row_parts = []
        for c in cols:
            raw = str(s.get(c, ""))
            value = _color_result(raw) if c == "result" else raw
            row_parts.append(f" {value:<{widths[c]}} ")
        row = "│" + "│".join(row_parts) + "│"
        log.info(row)

    log.info(border_bot)


# ============================================================
# SUMMARY
# ============================================================
def print_summary(active: list):
    results = [str(s.get("result", "")).lower() for s in active]

    created = sum("session created" in r for r in results)
    timeouts = sum("timeout" in r for r in results)
    unreachable = sum("not pingable" in r for r in results)
    failed = sum(r.startswith("session failed") for r in results)

    log.info("")
    log.info("======Summary======:")
    log.info(f" Created:      {created}")
    log.info(f" Timeouts:      {timeouts}")
    log.info(f" Unreachable:   {unreachable}")
    log.info(f" Failed:        {failed}")


# ============================================================
# Networking
# ============================================================
def is_pingable(ip: str) -> bool:
    if platform.system() == "Windows":
        cmd = ["ping", "-n", "3", "-w", "500", ip]
        encoding = "cp950"
        up = "bytes="
        down = ("Request timed out", "Destination host unreachable")
    else:
        cmd = ["ping", "-c", "3", "-W", "1", ip]
        encoding = "utf-8"
        up = "bytes from"
        down = ("100% packet loss", "unreachable")

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, encoding=encoding, errors="replace")
        output = result.stdout + result.stderr
        if up in output:
            return True
        if any(m in output for m in down):
            return False
    except:
        return False
    return False


def _pick_password(sut: dict) -> str:
    if sut["name"] in IUR_PASSWORD_EXCEPTIONS:
        return IUR_PASSWORD_EXCEPTIONS[sut["name"]]
    if sut["email"] == "nyen@hpe.com":
        return SUT_PASSWORD_NYE
    return SUT_PASSWORD_DEFAULT


def create_redfish_session(sut: dict) -> str:
    url = f"https://{sut['ilo_ip']}/redfish/v1/SessionService/Sessions/"
    headers = {"Accept": "application/json", "Content-Type": "application/json"}
    body = {"UserName": "temp-admin", "Password": _pick_password(sut)}

    def _post(session, timeout):
        r = session.post(url, headers=headers, json=body, verify=False, timeout=timeout)
        code = r.status_code
        r.close()
        return code

    with requests.Session() as sess:
        sess.trust_env = False
        try:
            code = _post(sess, timeout=15)
            return "Session created" if code == 201 else f"Session failed (HTTP {code})"
        except requests.exceptions.ReadTimeout:
            try:
                code = _post(sess, timeout=30)
                return "Session created (retry)" if code == 201 else f"Session failed (HTTP {code})"
            except:
                return "Session failed: timeout"
        except Exception as e:
            return f"Session failed → {e}"


# ============================================================
# Worker processing
# ============================================================
def process_active_suts(active: list, max_workers: int = 10):
    def _process(sut):
        sut["result"] = (
            create_redfish_session(sut)
            if is_pingable(sut["ilo_ip"])
            else "iLO not pingable"
        )
        return sut

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(_process, sut): sut for sut in active}
        for f in as_completed(futures):
            try:
                f.result()
            except Exception as e:
                futures[f]["result"] = f"Unexpected error → {e}"


# ============================================================
# BlueBird API
# ============================================================
def _build_bb_url(link_type: str, member: str) -> str:
    if link_type == "all":
        return f"{BB_BASE}?limit=100&offset=0&reservation_requester={member}"
    return (
        f"{BB_BASE}?limit=100&offset=0"
        f"&ordering=-id&quick_filter=low_utilized_suts"
        f"&bb_sut_status=not_archived_spare&since=3"
        f"&reservation_requester={member}"
    )


def _parse_dt(dt: str):
    if not dt:
        return None
    try:
        return datetime.fromisoformat(dt.replace("Z", "+00:00"))
    except:
        return None


def _is_reservation_active(ar: dict, member: str) -> bool:
    if not ar or ar.get("creator_email") != member:
        return False
    start = _parse_dt(ar.get("start", ""))
    if start is None:
        return False
    return start <= datetime.now(timezone.utc)


def _make_sut(entry: dict, member: str):
    ar = entry.get("active_reservation")
    if not _is_reservation_active(ar, member):
        return None

    return {
        "email": member,
        "name": entry.get("name", ""),
        "product_name": entry.get("product_name", ""),
        "ilo_connect_status": entry.get("ilo_connect_status", ""),
        "ilo_ip": entry.get("ilo_ip", ""),
        "active_end_time": ar.get("end", ""),
        "result": "",
    }


def fetch_suts_from_bluebird(link_type: str):
    if not BB_TOKEN:
        log.warning("BB_TOKEN is not set.")

    headers = {"Authorization": f"Token {BB_TOKEN}"}
    booked, active = [], []
    seen = set()

    for member in MEMBER_EMAILS:
        url = _build_bb_url(link_type, member)
        try:
            r = requests.get(url, headers=headers, verify=False, timeout=10)
            if r.status_code != 200:
                log.warning(f"BlueBird HTTP {r.status_code} for {member}")
                r.close()
                continue

            for entry in r.json().get("results", []):
                sut = _make_sut(entry, member)
                if sut is None:
                    continue

                if sut["name"] not in seen:
                    seen.add(sut["name"])
                    active.append(sut)
                else:
                    booked.append(sut)

            r.close()
        except Exception as e:
            log.warning(f"Failed fetching SUTs for {member}: {e}")

    return booked, active


# ============================================================
# Main Loop
# ============================================================
def main(delay: int = 600, workers: int = 10):
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    while True:
        cycle_start = time.time()

        section("Fetching SUTs from BlueBird")
        booked, active = fetch_suts_from_bluebird("all")

        # Exclusions
        excluded = [s for s in active if s["name"] in EXCLUDE_IURS]
        active = [s for s in active if s["name"] not in EXCLUDE_IURS]

        if excluded:
            log.warning("Excluded IURs (skipped this cycle):")
            for s in excluded:
                log.warning(f"  - {s['name']}  ({s['ilo_ip']})")
        else:
            log.info("No IURs matched exclusion list.")

        # Hardcoded additions
        existing_ips = {s["ilo_ip"] for s in active}
        for ip, name, product in EXCEPTION_IPS:
            if ip not in existing_ips:
                active.append({
                    "email": "Exception",
                    "name": name,
                    "product_name": product,
                    "ilo_connect_status": "NA in BB",
                    "ilo_ip": ip,
                    "active_end_time": "",
                    "result": "",
                })
                log.info("")
                log.warning(f"Added hardcoded exception: {name} ({ip})")

        section(f"Processing {len(active)} active SUTs (workers={workers})")
        process_active_suts(active, max_workers=workers)


        if booked:
            section("BOOKED SUTs")
            print_SUTs_info(booked, columns=BOOKED_COLS)


        section("ACTIVE SUTs")
        print_SUTs_info(active, columns=ACTIVE_COLS)
        print_summary(active)

        section("SUCCESS SUTs (session created)")
        print_SUTs_info([s for s in active if "session created" in s["result"].lower()], RESULT_COLS)

        section("FAILED / UNREACHABLE SUTs")
        print_SUTs_info([s for s in active if "session created" not in s["result"].lower()], RESULT_COLS)

        section("LOW UTILIZED SUTs")
        _, low = fetch_suts_from_bluebird("low_utilized_suts")
        print_SUTs_info(low, columns=LOW_COLS)

        elapsed = int(time.time() - cycle_start)
        log.info("")
        log.info(f"Cycle completed in {elapsed}s. Next run in 10 mins.")
        time.sleep(delay)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="SUT session creator")
    parser.add_argument("--delay", type=int, default=600)
    parser.add_argument("--workers", type=int, default=10)
    args = parser.parse_args()

    try:
        main(delay=args.delay, workers=args.workers)
    except KeyboardInterrupt:
        log.info("Exiting on user request.")