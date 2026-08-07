# keti-reconfig

KETI TSN 재구성 데모. 안드로이드 태블릿이 **LAN9662 스위치**와 **패스 모듈**을 직접 제어하고,
스위치 상태·성능을 태블릿에 표시한다.

이전 데모(`hwkim3330/pleos`)와의 차이는 **중간 감독자(7인치 ESP)를 없앴다**는 것이다.
그 보드가 멈추면 체인 전체가 죽었고, 실제로 그렇게 죽었다. 태블릿이 각 장치에 직접 붙는다.

## 구성

```
                    ┌── WiFi/Ethernet ──> LAN9662 스위치 (192.168.1.10)
Android 태블릿 ─────┤
                    └── BLE ────────────> 패스 모듈 (ESP32-S3 SuperMini)
                                          └── 페일 인젝션 모듈에 장착
```

## 확인된 사실 (2026-08-07 실측)

측정하지 않은 것은 아래 "미확인"에 따로 적는다.

### LAN9662 스위치

| 항목 | 값 |
|------|-----|
| 접속 | `/dev/ttyACM2` — Microchip MCP2221 USB-UART 브리지 (`04d8:00dd`) |
| 프로토콜 | MUP1 (시리얼), CoAP/CBOR over UDP 5683 (IP) |
| YANG 카탈로그 체크섬 | `5151bae07677b1501f9cf52637f2a38f` — 54개 YANG / 54개 SID |
| 데이터 포트 | `1` (oper-status up), `2` (down) — 둘 다 ethernetCsmacd |
| 관리 IP | `L3V1` = **192.168.1.10/24** static, oper-status up, MAC `52-D0-9D-B2-96-00` |
| fetch 왕복 | 전체 인터페이스 트리 약 0.4 s → **1 Hz 폴링 여유** |

관리 IP는 원래 없었다. `keti-tsn-cli`의 `setup/setup-ip-static.yaml`로 L3 VLAN 인터페이스를
만들어 부여했고, `save-config`로 플래시에 저장했다. 최초 설정은 MUP1(시리얼)로만 가능하다.

읽히는 데이터: 포트별 in/out octets·unicast·multicast·broadcast·discards·errors,
이더넷 프레임 통계(FCS/oversize/undersize 오류 포함), 브리지 포트 통계,
그리고 **TAS 게이트 파라미터**(`ieee802-dot1q-sched-bridge:gate-parameter-table`).
대시보드 그래프에 필요한 것은 이미 다 나온다.

### ESP32-S3 보드 2개

| 포트 | 칩 | 플래시 / PSRAM | 역할 |
|------|-----|---------------|------|
| `/dev/ttyACM1` | ESP32-S3 (QFN56) rev v0.2 | 4MB 내장(XMC) / 2MB | **패스 모듈** (SuperMini) |
| `/dev/ttyACM3` | ESP32-S3 (QFN56) rev v0.2 | 16MB / 8MB | **스위치 제어** |

큰 쪽에 WIZnet 이더넷 칩이 있다. 핀맵은 아직 미확인 — `tools/eth_probe/` 참고.

## 미확인 / 열린 항목

- **W5500 핀맵.** 후보 4개를 리셋 해제 없이 읽어 전부 `0x00`이 나왔는데, 리셋을 안 푼 것이
  원인일 가능성이 크다. 리셋을 다루는 프로브가 `tools/eth_probe/`에 있다.
- **ESP의 IP.** W5500이 붙으면 이 보드도 주소가 필요하다. 스위치가 192.168.1.10/24이므로
  같은 대역에서 static으로 준다 (예: 192.168.1.20).
- **SuperMini LED.** GPIO48로 추정. `tools/led_probe/`가 GPIO48/21 × 어드레서블/일반을
  순서대로 점등해 육안으로 확정하게 한다.
- **9662 두 데이터 포트의 물리적 결선.** 어디에 꽂혀 있는지 미확인.

## 하드웨어를 다룰 때 주의

**ESP32-S3의 GPIO19/20은 네이티브 USB D-/D+ 다.** 이 핀을 다른 용도로 재설정하면 USB가
즉시 끊기고, 보드는 BOOT 버튼을 누른 채 다시 꽂아야 복구된다. 핀을 훑는 프로브에서는
19/20을 반드시 제외할 것 — 한 번 당했다.

## 관련 저장소

- `hwkim3330/keti-tsn-cli` — MUP1/CoAP/CBOR/delta-SID를 구현한 JS CLI. 이 프로젝트의
  기준 구현이며, ESP 펌웨어와 SID 테이블은 여기서 파생한다.
- `hwkim3330/pleos` — 이전 3-ESP 데모. 태블릿 앱(`pleos_reconfig_studio`)과 차량 모델을
  가져다 쓴다.
