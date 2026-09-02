# Kontron KSwitch D10 (Microchip IStaX) — Running-Config Dump (3 switches)

> **READ-ONLY snapshot.** Captured **2026-09-02** via JSON-RPC (`.get`/`.status` methods only, no config was changed).
> Source of method names: `docs/D10_SWITCH_REFERENCE.md`. Raw JSON kept only in scratchpad (not committed).
> Access: `POST http://<ip>/json_rpc`, HTTP Basic `admin` / **empty password**, from PC USB NIC `enxc84d44263ba6` (192.168.100.50/24).
>
> **Note on completeness:** IStaX has no downloadable `running-config` file over JSON-RPC (only `startup-config` + `default-config` exist as files, and neither is fetchable by URL on this build). This dump was therefore assembled from per-subsystem `.get` methods, which return the **live running values**.

---

## 0. Switch → Role → Devices map

| IP | Role | Hostname | Mgmt MAC (BoardMac) | STP BridgeId | Notes |
|----|------|----------|---------------------|--------------|-------|
| **192.168.100.1** | **A** | `keti1` | `00:80:82:B9:64:B3` | `8000008082b964b3` | Source-side switch |
| **192.168.100.2** | **B** | `keti2` | `00:80:82:B9:65:2B` | `8000008082b9652b` | Detour switch (FRER generation) |
| **192.168.100.4** | **C** | `keti4` | `00:80:82:B9:64:9F` | `8000008082b9649f` | **STP root** + PC + RX-side (FRER recovery) |

Role assignment verified empirically: MACs match the reference doc, and only **C (.4)** has **Gi1/2 up** (= PC), which is C's defining trait.

### Physical topology (ring of 3)

```
keti-src(.77.10) ─Gi1/1→ [A .100.1] ─Gi1/6──Gi1/4─ [C .100.4] ─Gi1/1→ keti-rx(.77.12 / .6.2)
                            │Gi1/4                     │Gi1/6              Gi1/2→ PC(.100.50)
                            └────Gi1/4──[B .100.2]──Gi1/6┘
```

Ring links: **A Gi1/4 ↔ B Gi1/4**, **A Gi1/6 ↔ C Gi1/4** (video direct path), **B Gi1/6 ↔ C Gi1/6** (detour).
Each switch **Gi1/1 = its own Raspberry Pi**. **C Gi1/2 = PC**.

### Port → device cross-reference

| Port | A (.1) | B (.2) | C (.4) |
|------|--------|--------|--------|
| Gi 1/1 | keti-src Pi (.77.10, video src) — UP | keti-tx Pi (.100.10, flood) — UP | keti-rx Pi (.77.12/.6.2, display) — UP |
| Gi 1/2 | — down | — down | **PC (.100.50)** — UP |
| Gi 1/3 | — down | — down | — down |
| Gi 1/4 | ring → B Gi1/4 — UP | ring → A Gi1/4 — UP (**STP blocked**) | ring → A Gi1/6 (direct) — UP |
| Gi 1/5 | — down | — down | — down |
| Gi 1/6 | ring → C Gi1/4 (direct) — UP | ring → C Gi1/6 (detour) — UP | ring → B Gi1/6 (detour) — UP |
| 2.5G 1/1-2 | — down | — down | — down |

---

## 1. Platform / System (identical build on all three)

| Field | Value |
|-------|-------|
| Board | Kontron KSwitch D10 (S1921), BoardID 1921 |
| Chip | LAN9668 Rev. B, 8 ports |
| Product | Microchip IStaX Switch |
| Firmware version | **GA-2.02-20230614072053** (built 2023-06-14) |
| Board serial | (empty) |
| Contact / Location | (unset) |

| Role | Hostname | Uptime @ capture | CPU (get returned OK) |
|------|----------|------------------|-----------------------|
| A | keti1 | 03:26:40 | ok |
| B | keti2 | 03:26:44 | ok |
| C | keti4 | 03:26:40 | ok |

Config files on flash (`icfg.status.file.get`): `default-config` (629 B, r-) and `startup-config` (1256 B, rw, last modified **2023-06-14**). The startup-config has **not** been re-saved since factory — so the live running-config below (FRER/VCL/CBS) exists in RAM only and would be **lost on reboot**.

---

## 2. Ports (status + config)

All ports: admin **Shutdown=false**, Speed=**autoNegMode**, FlowControl=off, default MTU. Link state:

| Port | A link | B link | C link | Speed (when up) |
|------|--------|--------|--------|-----------------|
| Gi 1/1 | UP | UP | UP | 1G FDX |
| Gi 1/2 | down | down | **UP** | 1G FDX |
| Gi 1/3 | down | down | down | — |
| Gi 1/4 | UP | UP | UP | 1G FDX |
| Gi 1/5 | down | down | down | — |
| Gi 1/6 | UP | UP | UP | 1G FDX |
| 2.5G 1/1 | down | down | down | — |
| 2.5G 1/2 | down | down | down | — |

Port integer index (for web forms / app): Gi1/1..1/6 = **1..6**, 2.5G 1/1-2 = **7-8**.

---

## 3. VLAN

**All three switches are VLAN-default.** No custom VLANs, no tagging.

| Setting | Value (all switches, all ports) |
|---------|--------------------------------|
| `vlan.config.global.main` | AccessVlans = **[1]**, CustomSPortEtherType = 0x88A8 (34984) |
| Per-port mode | **access**, AccessVlan = **1** |
| Named VLANs | none (defaults `VLAN0001…` only) |

So the whole rig is a single flat L2 broadcast domain (VLAN 1). FRER's `FrerVlan` = 1 accordingly.

---

## 4. FRER (802.1CB) + VCL stream classification

| | A (.1) | B (.2) | C (.4) |
|--|--------|--------|--------|
| FRER instance | **none** | **#1 generation** | **#1 recovery** |
| VCL stream #1 | none | dst-MAC match | dst-MAC match |

### VCL stream #1 (B and C, identical)
- `destinationMacAddress` = **`DC:A6:32:17:77:6E`** (keti-rx video RX MAC), mask `FF:FF:FF:FF:FF:FF`
- srcMAC any, outerTag any, protocol ANY
- `vcl.status.stream`: **frerClientAttached = true, frerClientId = 1** (bound to the FRER instance); psfpClientAttached = false
- ⚠️ `vcl.config.interface.stream` (the per-port iflow / "VCL MAC matching" binding) is **empty** on all switches — the raw-JSON stream match exists but the port→stream iflow the reference warns must be set via the web form is not present here.

### FRER #1 on B (.2) — Generation
| Field | Value |
|-------|-------|
| Mode | generation |
| StreamId0 | 1 (streams_list = "1") |
| EgressPorts | **Gi 1/4, Gi 1/6** |
| FrerVlan | 1 |
| Algorithm | vector, HistoryLen 8, ResetTimeout 100 ms |
| AdminActive | true |
| OperState | **active** |
| **Warning** | **WarningIngressNoLink = true** (all other warnings false) |

### FRER #1 on C (.4) — Recovery
| Field | Value |
|-------|-------|
| Mode | recovery |
| StreamId0 | 1 |
| EgressPorts | **Gi 1/2** (= PC port) |
| Terminate | **true** |
| FrerVlan | 1 |
| Algorithm | vector, HistoryLen 8, ResetTimeout 100 ms |
| AdminActive | true |
| OperState | **active**, WarningNone = true (clean) |

> **Assessment (matches reference doc):** B=generation, C=recovery(egress Gi1/2). Both are **misaligned with the real video path** (A→C direct, video egress = C Gi1/1). C recovers onto **Gi1/2 (PC)**, not Gi1/1 (RX Pi). B's generation shows `IngressNoLink`. So FRER is configured but **does not actually protect the live video stream** — video flows as plain L2. A has no FRER at all. A recovery to make dual-path protection real is documented in `D10_SWITCH_REFERENCE.md §6`.

---

## 5. CBS (802.1Qav — queue shaper)

Only **one** shaper is enabled across the whole rig:

| Switch | Port | Queue | Enable | Credit (CBS) | Cir | RateType | Excess |
|--------|------|-------|--------|--------------|-----|----------|--------|
| **C (.4)** | **Gi 1/2** | **6** | true | **true** | **250000 kbps (250 Mbps)** | line | false |

- A and B: **no** queue shapers, **no** port shapers enabled.
- C: only the above; no port shaper.
- ⚠️ CBS is on **Gi1/2 (PC port)**, not on Gi1/1 (video RX egress). Per the reference, protecting the actual video would require the shaper on **C Gi1/1 q6**; the current placement is the known "wrong port" from the old demo.

---

## 6. TAS / GCL (802.1Qbv)

**Not configured anywhere.** On all three switches:
- `tsn.config.global`: Procedure = `timeonly`, Timeout = 20, PtpPort = 0 (defaults).
- TAS: **no port has GateEnabled=true**; no GCL entries; no per-port maxSdu overrides.

---

## 7. MSTP / Spanning-Tree

Bridge config identical on all three (RSTP/MSTP defaults): ForceVersion **mstp**, MaxAge 20, HelloTime 2, FwdDelay 15, TxHoldCount 6, MaxHops 20, BpduGuard/Filtering off, all ports Enable=true, edge auto.

**C (.4) is the CIST root** (lowest BridgeId `8000008082b9649f`). The triangular ring loop is broken by **B blocking Gi1/4**:

| Switch | Port | Role | State | Designated Bridge |
|--------|------|------|-------|-------------------|
| A (.1) | Gi 1/1 | DesignatedPort | forwarding | self |
| A (.1) | Gi 1/4 | DesignatedPort | forwarding | self (→ B, which blocks its end) |
| A (.1) | Gi 1/6 | **RootPort** | forwarding | C (root, direct link) |
| B (.2) | Gi 1/1 | DesignatedPort | forwarding | self |
| B (.2) | **Gi 1/4** | **AlternatePort** | **discarding** ⛔ | A |
| B (.2) | Gi 1/6 | **RootPort** | forwarding | C (root) |
| C (.4) | Gi 1/1 | DesignatedPort | forwarding | self (root) |
| C (.4) | Gi 1/2 | DesignatedPort | forwarding | self (root) |
| C (.4) | Gi 1/4 | DesignatedPort | forwarding | self (root) |
| C (.4) | Gi 1/6 | DesignatedPort | forwarding | self (root) |

> **Blocked ring link = B Gi1/4** (the A↔B leg). This is the STP-vs-FRER conflict from the reference: FRER wants both ring paths, but STP discards B Gi1/4, so B's generation copies can't traverse the A↔B leg. All other links forward.

---

## 8. PSFP (802.1Qci)

**Not present / empty** on all three switches: `psfp.config.stream_filter`, `stream_gate`, `flow_meter`, `gcl` all return `[]`.

---

## 9. Summary of what is actually configured (delta from factory)

| Subsystem | A (.1) | B (.2) | C (.4) |
|-----------|--------|--------|--------|
| VLAN | default (VLAN1) | default | default |
| FRER | — | #1 generation (Gi1/4,1/6) | #1 recovery (Gi1/2, terminate) |
| VCL stream | — | #1 dst `DC:A6:32:17:77:6E` | #1 dst `DC:A6:32:17:77:6E` |
| CBS | — | — | Gi1/2 q6, 250 Mbps, credit |
| TAS | — | — | — |
| PSFP | — | — | — |
| MSTP | root-port Gi1/6 | **blocks Gi1/4** | **root bridge** |

**Not saved to startup:** all FRER/VCL/CBS above are running-config only (startup-config dates to 2023). A reboot reverts to a bare L2 switch.

---

### Appendix — method names used (all `.get`, read-only)
`systemUtility.status.boardinfo` · `systemUtility.config.systemInfo` · `systemUtility.status.systemUptime` · `firmware.status.switch` · `port.status` · `port.config` · `vlan.config.global.main` · `vlan.config.interface` · `vlan.config.global.name` · `frer.config` · `frer.status` · `vcl.config.stream` · `vcl.status.stream` · `vcl.config.interface.stream` · `qos.config.interface.queueShaper` · `qos.config.interface.shaper` · `tsn.config.global` · `tsn.config.interface.tas.params` · `tsn.config.interface.tas.gclEntry` · `tsn.config.interface.tas.maxSdu` · `mstp.config.bridge` · `mstp.status.bridge` · `mstp.config.cist.interface` · `mstp.status.interface` · `mstp.statistics.interface` · `psfp.config.*` · `icfg.status.file`
