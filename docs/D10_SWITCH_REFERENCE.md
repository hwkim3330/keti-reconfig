# Kontron KSwitch D10 (Microchip IStaX) — 실기 레퍼런스

이 문서는 KETI reconfig 데모의 D10 스위치 3대를 실제로 조작하며 검증한 내용이다.
정본은 실기지만, JSON-RPC 메서드/포맷/함정은 여기 정리한다.

## 1. 접속

| 방법 | 상세 |
|---|---|
| **JSON-RPC** | `POST http://<ip>/json_rpc`, Basic auth **admin / (빈 비번)**, `Content-Type: application/json` |
| **웹 UI** | `http://<ip>` (admin/공백) — **classic IStaX 프레임 UI**, `lib/json.js`로 내부는 JSON-RPC |
| **SSH CLI** | 포트 22, admin/공백 — WebStaX 산업용 CLI(bash 아님, 비대화형은 세션 닫힘) |
| **전체 메서드 스펙** | `GET http://<ip>/json_spec` (약 2980개 메서드, 1.8MB JSON) |
| **PC 접근** | 이 PC는 USB 랜카드 `enxc84d44263ba6`(D10-4 2번포트)에 `192.168.100.50/24` 부여해야 닿음. 기본 라우트는 사무실GW로 새서 안 됨. PC sudo=`1`. |

## 2. 리그 토폴로지 (실측)

```
keti-src(.77.10) ─Gi1/1→ [D10-1/A .100.1] ─Gi1/6→ [D10-4/C .100.4] ─Gi1/1→ keti-rx(.77.12)
                              │ Gi1/4                  │ Gi1/6
                              └──── [D10-2/B .100.2] ───┘
```
- **영상 실제 경로(직행만)**: keti-src → A Gi1/1 → **A Gi1/6 → C Gi1/4** → C Gi1/1 → keti-rx
- 링 배선: A Gi1/4↔B Gi1/4, **A Gi1/6↔C Gi1/4(직행)**, B Gi1/6↔C Gi1/6(우회)
- 각 Pi = 자기 스위치 Gi1/1. PC = C Gi1/2.
- 수신 keti-rx MAC = **DC:A6:32:17:77:6E** (영상 dst MAC, FRER 스트림 매칭 기준)
- 스위치 mgmt MAC: A `00:80:82:b9:64:b3`, B `:65:2b`, C `:64:9f`
- 포트 정수 인덱스(웹 폼용): Gi1/1..1/6 = **1..6**, 2.5G 1/1-2 = 7-8

## 3. 포트 상태 / 통계

```jsonc
// 링크 상태 (Link/Speed 등)
port.status.get [<port|없으면 전체>]          // → [{key:"Gi 1/1", val:{Link, Speed:"speed1G", Fdx,...}}]
// 카운터 (rate 계산용). ★ port.statistics.get 은 없음, .ifGroup/.rmon 사용
port.statistics.ifGroup.get ["Gi 1/1"]        // → {RxOctets, TxOctets, RxUnicastPkts,...}
port.statistics.rmon.get ["Gi 1/1"]           // RMON 카운터
// 포트 down/up (get-modify-set)
port.config.get ["Gi 1/1"] → {...Shutdown:false...}
port.config.set ["Gi 1/1", {...Shutdown:true}]
```
영상 비트레이트 = C Gi1/1 `TxOctets` 델타(실측 8.6 Mbps). ping은 Pi/브리지에서(스위치 CLI ping은 웹UI 전용).

## 4. CBS (802.1Qav) — queue shaper

```jsonc
qos.config.interface.queueShaper.get ["Gi 1/1", 6]
qos.config.interface.queueShaper.set ["Gi 1/1", 6,
   {Enable:true, Credit:true, Cir:250000, RateType:"line", Excess:false}]  // Cir=kbps
```
- **★ 영상 실제 출구 = C Gi1/1**(수신 Pi). CBS는 여기 q6에 걸어야 영상 보호. (예전 데모는 Gi1/2에 잘못 걸려 있었음)
- 영상 = **TC6**(PCP6→q6), 플러드 = **TC0**(pktgen untagged→q0). 링 포트(Gi1/4·1/6) TrustTag=true.
- 주의: TC6 vs TC0는 strict priority라 영상이 이미 이김 → 플러드로 깨짐 재현하려면 플러드를 같은/높은 큐로 올리거나 링크 포화.

## 5. VCL 스트림 분류 (FRER의 ingress)

두 계층:
```jsonc
vcl.config.stream.get [1]     // 전역 스트림 정의(매칭 필터)
vcl.config.stream.add [1, {destinationMacAddress:"DC:A6:32:17:77:6E", destinationMacMask:"FF:...FF",
                           outerTag:"any", protocol:"ANY", ...}]   // ★ 생성은 .add (.set 은 MESA_RC_ERROR)
```
- **iflow(포트↔스트림 바인딩)** = 웹 페이지 `vcl_port_stream_config.htm`의 **"VCL MAC matching"** 포트별 드롭다운.
  값: `Source MAC`(default) / **`Destination MAC`(val=`dmac_dip`)**. ★ 이건 raw JSON-RPC로 못 만듦(val 구조가 안 잡힘), **웹 폼으로만** 확실히 됨.
- 즉 영상(dst MAC 매칭)을 A Gi1/1에서 분류하려면: 스트림 정의 + **A Gi1/1 = Destination MAC(웹)**.

## 6. FRER (802.1CB)

```jsonc
frer.config.get [1]           // 인스턴스 설정
frer.config.add [<id>, {...}] // 생성 (웹 Save도 이 메서드 호출)
frer.config.set [1, {...}]    // 수정
frer.config.del [1]           // 삭제
frer.status.get [1]           // OperState + Warning* (StreamNotFound, IngressNoLink 등)
frer.statistics.get [1, "Gi 1/1", 0]   // {Passed, Discarded, OutOfOrder, Tagless,...} (port, dpl)
```
**웹 폼(frer_ctrl.htm) 필드**: Mode(Generation/Recovery), streams_list=`"1"`, egress_ports=**정수** `"4,6"`(슬래시 금지), FrerVlan, Algorithm(Vector/Match), Terminate 등.

### 현재 상태 (2026-09-01)
- B=generation, C=recovery(egress Gi1/2) — **둘 다 영상 실제 경로(A→C 직행, egress Gi1/1)와 어긋나 있어 영상을 실제로 보호 안 함.** 영상은 FRER 안 거치고 평범한 L2로 흐름.

### 이중경로 보호로 만들려면 (목표 레시피)
1. **A 에 Generation**: 웹 frer_ctrl ⊕ → Mode=Generation, Ingress Streams=`1`, Egress=`4,6`(Gi1/4·1/6), Enable
2. **A Gi1/1 = Destination MAC** (웹 vcl_port_stream_config)
3. **A 스트림 #1** (dst MAC 수신기) 정의 — ★ 웹 vcl_stream_ctrl.htm 으로 (iflow 위해)
4. **C Recovery egress → Gi1/1**, C Gi1/4·1/6 = Destination MAC
5. **B Generation 삭제**
6. 검증: 직행(A Gi1/6) 뽑아도 영상 유지 = 무결절

### ✅ 검증된 레시피 (웹 폼으로 하면 된다) + ⚠️ 최종 블록 = 스패닝트리
**JSON-RPC만으로는 iflow가 안 생긴다** — `vcl.config.stream.add`(match만) + `frer.config.add`로 만들면 `WarningStreamNotFound`거나 dormant. **핵심: 스트림의 iflow = 웹 스트림 폼(`vcl_stream_ctrl.htm`)의 `Member_N` 체크박스(포트 N+1)**. 이걸 웹으로 만들면 stream↔port 바인딩이 생긴다.

**웹 폼으로 A generation 완성(2026-09-01 실증)**:
1. `vcl_stream_ctrl.htm` ⊕ → stream_Id=`1`, destinationMacAddress=`DC:A6:32:17:77:6E`, mask=`FF:...FF`, protocol=`ANY`, **Member_0 체크(=Gi1/1)** → Save
2. `vcl_port_stream_config.htm` → Gi1/1 = `Destination MAC` → Save
3. `frer_ctrl.htm` ⊕ → Mode=Generation, streams_list=`1`, egress_ports=`4,6`, Enable → Save
→ **결과: A frer `Oper active, WarningNone`, 직행 사본이 R-TAG로 A Gi1/6→C 정상 흐름(영상 유지 9Mbps).** 여기까진 됐다.

**그런데 detour(A Gi1/4) 사본이 안 나감(TX 0).** 원인 = **MSTP(스패닝트리)가 링을 차단**:
- `mstp.status.interface.get` → **B Gi1/4 = `discarding`** (삼각 A-B-C 물리 루프를 STP가 한 링크 막음). A는 블록된 세그먼트로 generation 사본을 안 보냄.
- **FRER는 두 경로를 일부러 다 쓰는데 STP는 루프를 막는다 = 근본 충돌.** FRER 이중경로를 쓰려면 **링 포트(A/B/C의 Gi1/4·1/6)에서 STP를 꺼야** 한다.
- ⚠️ **그런데 삼각 물리 루프에서 STP 끄면 브로드캐스트 스톰 위험**(영상 unicast는 FRER dedup으로 괜찮지만 broadcast/ARP/unknown은 루프). 안전하게 하려면: 링을 **전용 VLAN으로 격리**하거나, 링 포트를 MSTP instance에서 빼거나, 콘솔 물린 상태에서 모니터링하며 STP off. **라이브에서 블라인드로 STP 끄지 말 것.**

**결론**: FRER 설정 자체는 웹 폼으로 완결 가능(레시피 위)하고, 남은 건 순수 **STP-vs-FRER-on-ring** 이슈다. 이건 링 격리 설계 결정이 필요하다.

### 되돌리기 안전망 (필수)
```jsonc
icfg.control.copy.set [{Copy:true, SourceConfigType:"startupConfig", DestinationConfigType:"runningConfig"}]
```
저장상태로 즉시 복원(영상 ~5s 회복). **매 실험 전 startup을 좋은 상태로 저장.** 실험 중 8회 시도·6회 영상 끊김 다 이걸로 복원했다. C recovery egress를 Gi1/1로 바꾸면 tagless 영상 discard하니 generation R-TAG가 먼저 있어야 함(순서 의존).

## 7. TAS (802.1Qbv)

```jsonc
tsn.config.interface.tas.params.get ["Gi 1/1"]
tsn.config.interface.tas.params.set ["Gi 1/1", {GateEnabled:true, AdminCycleTimeNumerator:us, AdminCycleTimeDenominator:1000000,...}]
tsn.config.interface.tas.gclEntry...   // gate control list
```
PSFP(802.1Qci)는 `psfp.config.*` (sfi/sgi/fmi). 웹: tsn_*.htm.

## 8. 설정 저장 / 되돌리기

```jsonc
// running → startup (재부팅 생존)
icfg.control.copy.set [{Copy:true, SourceConfigType:"runningConfig", DestinationConfigType:"startupConfig", Merge:false}]
// startup → running (되돌리기 = 안전망)
icfg.control.copy.set [{Copy:true, SourceConfigType:"startupConfig", DestinationConfigType:"runningConfig", Merge:false}]
```

## 9. 브라우저 자동화 (웹 폼용)

이 PC엔 playwright 1.56 / selenium 4.39 / puppeteer / chromium 있음. IStaX 프레임 UI 몰 때:
```python
ctx = await browser.new_context(http_credentials={"username":"admin","password":""})
await page.goto(url, wait_until="commit")   # ★ domcontentloaded 는 프레임에서 hang 가능
# FRER Add: click img[src*='add'] → select[name='Mode'] → input[name='streams_list']/'egress_ports' → input[value='Save']
# /json_rpc POST 요청 가로채면 웹이 실제로 치는 콜을 볼 수 있음
```
**함정**: 스위치가 반복 작업으로 느려지면 playwright Save가 hang한다(45s 타임아웃). 응답성 먼저 확인.
