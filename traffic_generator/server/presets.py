"""Canned stream sets for the LAN9662 TSN bench.

PCP -> traffic-class mapping used by the CBS tests in this lab:
    PCP 0-3 -> Priority 6 (TC6, 3.5 Mbps)
    PCP 4-7 -> Priority 2 (TC2, 1.5 Mbps)
"""

from __future__ import annotations

PRESETS: dict[str, dict] = {
    "cbs_tc2_tc6": {
        "label": "CBS TC2 + TC6",
        "note": "1.5 Mbps on PCP 5 (-> TC2) and 3.5 Mbps on PCP 1 (-> TC6).",
        "streams": [
            {
                "name": "TC6",
                "frame_size": 512,
                "vlan_id": 100,
                "pcp": 1,
                "rate_mode": "mbps",
                "rate_value": 3.5,
                "cpu": 0,
                "queue": 0,
            },
            {
                "name": "TC2",
                "frame_size": 512,
                "vlan_id": 100,
                "pcp": 5,
                "rate_mode": "mbps",
                "rate_value": 1.5,
                "cpu": 1,
                "queue": 1,
            },
        ],
    },
    "line_rate_1500": {
        "label": "1G line rate (1500B)",
        "note": "Full 81.3 kpps = a steady 1000 Mbps on the wire. Two streams on "
        "two cores because one Pi-4 core tops out ~79 kpps (969 Mbps); the pair "
        "saturates the NIC and the link caps the surplus at exact line rate.",
        "streams": [
            {
                "name": f"bulk{i}",
                "frame_size": 1518,
                "vlan_id": None,
                "pcp": 0,
                "rate_mode": "max",
                "rate_value": 0,
                "cpu": i,
                "queue": i,
                "clone_skb": 100000,
                "burst": 8,
            }
            for i in range(2)
        ],
    },
    "line_rate_512": {
        "label": "1G line rate (512B)",
        "note": "235 kpps. Still reachable on a Pi 4 with clone_skb + burst.",
        "streams": [
            {
                "name": "bulk",
                "frame_size": 512,
                "vlan_id": None,
                "pcp": 0,
                "rate_mode": "max",
                "rate_value": 0,
                "cpu": 0,
                "queue": 0,
                "clone_skb": 100000,
                "burst": 8,
            }
        ],
    },
    "small_frame_stress": {
        "label": "64B stress (4 cores)",
        "note": "Line rate needs 1.488 Mpps - a Pi 4 will NOT reach it. This measures the ceiling.",
        "streams": [
            {
                "name": f"q{i}",
                "frame_size": 64,
                "vlan_id": None,
                "pcp": 0,
                "rate_mode": "max",
                "rate_value": 0,
                "cpu": i,
                "queue": i,
                "clone_skb": 100000,
                "burst": 8,
            }
            for i in range(4)
        ],
    },
    "pcp_sweep": {
        "label": "PCP sweep (0/2/4/6)",
        "note": "Four tagged streams at 10 Mbps each - checks the switch's PCP->TC mapping.",
        "streams": [
            {
                "name": f"PCP{p}",
                "frame_size": 512,
                "vlan_id": 100,
                "pcp": p,
                "rate_mode": "mbps",
                "rate_value": 10.0,
                "cpu": i,
                "queue": i,
            }
            for i, p in enumerate((0, 2, 4, 6))
        ],
    },
    "flood_hi_512": {
        "label": "Flood · 512B · PCP7 (TC7)",
        "note": "Small-frame line rate tagged VLAN100 PCP7 -> TC7, so it OUTRANKS the "
        "best-effort video and starves it. This is the 'break the video' flood: without "
        "CBS the higher-priority storm wins; CBS reserving the video's queue is what saves it.",
        "streams": [
            {
                "name": "kill",
                "frame_size": 512,
                "vlan_id": 100,
                "pcp": 7,
                "rate_mode": "max",
                "rate_value": 0,
                "cpu": 0,
                "queue": 0,
                "clone_skb": 100000,
                "burst": 8,
            }
        ],
    },
    "flood_hi_64": {
        "label": "Flood · 64B · PCP7 (TC7)",
        "note": "64B PCP7 storm - the hardest hit at the highest class. Breaks the video "
        "hardest; CBS on the video queue is the only thing that protects it.",
        "streams": [
            {
                "name": f"kill{i}",
                "frame_size": 64,
                "vlan_id": 100,
                "pcp": 7,
                "rate_mode": "max",
                "rate_value": 0,
                "cpu": i,
                "queue": i,
                "clone_skb": 100000,
                "burst": 8,
            }
            for i in range(4)
        ],
    },
    "background_100m": {
        "label": "Background 100 Mbps",
        "note": "Untagged best-effort load to sit underneath a TSN measurement.",
        "streams": [
            {
                "name": "bg",
                "frame_size": 1518,
                "vlan_id": None,
                "pcp": 0,
                "rate_mode": "mbps",
                "rate_value": 100.0,
                "cpu": 0,
                "queue": 0,
            }
        ],
    },
}
