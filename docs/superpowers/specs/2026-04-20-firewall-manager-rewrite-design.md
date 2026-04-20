# firewall-manager 재작성 설계

날짜: 2026-04-20
상태: Draft — 구현 계획 이관 대기

## 1. 배경

현재 `firewall-manager`는 4,315줄(그 중 `lib/persist.sh` 945줄)로 커졌고 `load`가 안정적으로 동작하지 않는다. 사용자는 처음부터 다시 만들기로 결정했다.

재작성 목표는 **기능을 덜고, 네이티브 포맷을 쓰고, 커스텀 파싱을 없애는 것**이다. 과거 실패의 공통 원인은 `iptables-save` 출력을 직접 파싱·재구성하려 한 것이었다.

## 2. 사용 시나리오

1. 일상 운영 — 메뉴로 IP 추가/차단
2. 팀/그룹 관리 — ipset으로 허용 IP 묶음 관리
3. 백업/롤백 — 변경 후 문제가 생기면 되돌림
4. 재부팅 후 자동 복원 — config를 boot 시 live로 복원

**서버 이전(migration) 시나리오는 스코프에서 제외**했다. 이 때문에 현재 `lib/bundle.sh` (379줄)은 통째로 삭제된다.

## 3. 관리 범위 (스코프)

| 대상 | 포함 | 방향성 | 비고 |
|---|---|---|---|
| `filter/INPUT` | ✅ | source 기반 | 허용 + 차단 |
| `filter/DOCKER-USER` | ✅ | source 기반 | 허용 + 차단 |
| `filter/OUTPUT` | ✅ | destination 기반 | 도구가 **추가**할 수 있는 것은 DROP/REJECT만. 이미 존재하는 ACCEPT/기타 규칙은 **편집은 불가하지만 보존**됨 (§6 참조) |
| `filter/FORWARD` | ❌ | — | Docker가 관리하므로 충돌 회피 |
| `filter/DOCKER`, `DOCKER-INGRESS`, `DOCKER-ISOLATION-*` | ❌ | — | Docker 자체 관리 영역, 읽지도 쓰지도 않음 |
| `nat`, `mangle`, `raw` 테이블 | ❌ | — | |
| OUTPUT/INPUT default policy 변경 | ❌ | — | 자기-차단 방지 |
| `ipset hash:net` (with `comment`) | ✅ | — | 유일한 ipset 타입 |
| 그 외 ipset 타입 | ❌ | — | |

"관리 대상" 판단은 **config 파일에 있는 것 = 관리 대상**. 별도 레지스트리/접두사 없음.

## 4. 저장/복원 모델 — 자동 저장 (Model A)

### 4.1 모델 설명

명시적 `save` / `load` 명령 없음.

- **저장**: 모든 변경은 "live에 적용 → live 상태를 config로 덤프" 순서로 트랜잭션 처리. config는 "가장 최근 live의 스냅샷".
- **복원 = 롤백**: `config/backups/<timestamp>.tar.gz` 목록에서 선택해 복구.

이전 설계의 `save`/`load`/`sync`/`export`/`import` 명령 및 `live ↔ config` 양방향 동기화 로직은 전부 없앤다.

### 4.2 트랜잭션 순서 (모든 변경의 공통 경로)

```
1. flock 획득
2. config/ → config/backups/<timestamp>.tar.gz 백업  (이하 "이번 트랜잭션 백업")
3. live에 변경 적용 (iptables/ipset 명령 직접 실행)
4. 실패 시: 이번 트랜잭션 백업에서 원복, 에러 전달, 종료
5. 성공 시: live → config/*.rules 덤프
6. 위험 규칙(DROP/REJECT)이었으면 60초 확인 타이머
   타임아웃 시 이번 트랜잭션 백업에서 원복
7. flock 해제
```

**핵심: config를 먼저 쓰고 live에 적용하면 live/config 불일치가 발생할 수 있다. 순서는 반드시 live → config.**

### 4.3 저장 포맷

파일 포맷은 `iptables-save` / `ipset save`의 **네이티브 출력 그대로**. 커스텀 파싱 0.

### 4.4 복원

1. `ipset restore < config/ipsets.rules` **먼저**
2. `iptables-restore --noflush < config/iptables.rules` **나중**

순서가 틀리면 iptables 규칙이 존재하지 않는 ipset을 참조해서 실패한다.

`--noflush` + `:INPUT/:OUTPUT/:DOCKER-USER` 선언만 파일에 포함하므로, 파일에 없는 `DOCKER`, `FORWARD` 등은 건드려지지 않는다.

### 4.5 백업 정책

- 변경 발생 시마다 `config/backups/YYYY-MM-DD_HH-MM-SS.tar.gz` 생성
- 최근 20개 유지, 초과분은 오래된 것부터 삭제
- 롤백 UI에서 선택형 복원

## 5. 팀(ipset) 메타데이터

전부 ipset 네이티브 기능 사용:

| 정보 | 저장 위치 |
|---|---|
| 팀 이름 | ipset set 이름 |
| 팀 설명 | ipset 자체의 `comment` |
| 멤버 IP | 엔트리 |
| 멤버별 설명 (누구 IP인지) | 각 엔트리의 `comment` — **필수 입력** |

신규 set 생성 시 항상 `ipset create <name> hash:net comment`로 생성한다. 기존에 `comment` 옵션 없이 만들어진 set은 "코멘트 없는 팀"으로 취급하며 재생성을 자동으로 제안하지 않는다.

**별도 `config/teams/*.conf` 파일 없음.** `config/ipsets.rules` 하나로 충분.

## 6. 첫 실행 (Bootstrap)

```
1. config/ 없음 감지
2. live 스캔:
   - INPUT 규칙 전체
   - DOCKER-USER 규칙 전체 (Docker 실행 시)
   - OUTPUT 규칙 전체 (ACCEPT/기타 포함 모두 import — §6.1 참조)
   - 기존 ipset 목록
3. 기존 ipset을 체크리스트로 보여주고 관리 대상 선택 (기본 전체 체크)
4. 선택된 상태를 config/iptables.rules, config/ipsets.rules 로 덤프
5. initial backup 생성
```

첫 실행은 live를 **변경하지 않는다**. 오직 읽기 + config 초기화.

### 6.1 OUTPUT ACCEPT/기타 규칙 처리

OUTPUT 체인은 복원 시 `:OUTPUT <policy> [0:0]`로 flush되므로, config에 없는 OUTPUT 규칙은 다음 복원 때 소실된다. 따라서 **bootstrap 시 OUTPUT의 모든 기존 규칙(ACCEPT 포함)을 import**한다.

- 사용자는 메뉴에서 이 규칙들을 **추가로 만들 수 없음** (DROP/REJECT 추가 메뉴만 제공)
- 하지만 **보존됨** — config에 들어가 있고, `iptables-save`가 라운드트립 보장
- 삭제는 "규칙 삭제" 메뉴에서 목록으로 선택 가능 (어떤 규칙이든 삭제는 허용)

이는 INPUT/DOCKER-USER와 마찬가지로 "체인 전체를 관리하되, 추가 가능한 규칙 종류만 제한"하는 모델이다.

## 7. 안전장치

| # | 장치 | 동작 |
|---|---|---|
| 1 | SSH 차단 경고 | SSH 포트 차단 가능성 있는 규칙 추가 시 경고 + 확인. 포트는 `$SSH_CONNECTION`의 4번째 필드(server port)를 우선 사용, 없으면 22 기본. |
| 2 | 60초 안전 타이머 | DROP/REJECT 규칙 추가 후 60초 내 확인 없으면 가장 최근 백업으로 자동 원복 |
| 3 | ESTABLISHED,RELATED 감지 | INPUT에 해당 규칙 없으면 경고. 자동 삽입은 사용자 확인 후. |
| 4 | 변경 전 자동 백업 | §4.2 참조 — 모든 변경 앞에 백업 |
| 5 | 원자적 복원 | `iptables-restore` 실패 시 backup에서 즉시 복원 |
| 6 | flock | 동시 실행 직렬화 (`/var/lock/fw-manager.lock`) |

이 외의 안전장치(자기 IP 자동 감지 fallback 체인, 커널 모듈 preflight 체크리스트, iptables-legacy/nft 구분, dry-run 플래그 등)는 **YAGNI로 제외**한다. 에러 메시지는 iptables/ipset 원본 메시지를 그대로 사용자에게 노출한다.

## 8. 메뉴 구조

### 대화형 (`sudo ./fw`)

```
1) 규칙 관리
   - INPUT 허용 추가 / 차단 추가
   - DOCKER-USER 허용 추가 / 차단 추가
   - OUTPUT 차단 추가 (destination: IP/CIDR/팀)
   - 규칙 삭제 (체인별 목록에서 화살표 선택)
2) 팀 관리 (ipset)
   - 팀 생성 / 삭제
   - 멤버 추가 (IP/CIDR + 코멘트 필수) / 삭제 (목록에서 선택)
3) 롤백
   - 최근 20개 백업에서 선택 → 복원
4) 현재 상태 보기
   - INPUT/DOCKER-USER/OUTPUT 규칙 + 팀 목록 요약
0) 종료
```

### 비대화형

- `sudo ./fw status` — 현재 상태 표시
- `sudo ./fw rollback [index]` — index 생략 시 인덱스 목록, 숫자 주면 해당 백업으로 복원
- `sudo ./fw --help`

기존의 `save`/`load`/`sync`/`preflight`/`export`/`import` 명령은 **삭제**.

## 9. 디렉토리 구조

```
firewall-manager/
├── fw                        # 엔트리포인트 (60~100줄)
├── lib/
│   ├── common.sh             # 색상/로그/메뉴/프롬프트/flock 래퍼
│   ├── scope.sh              # iptables-save / ipset save 출력에서 관리 대상만 필터
│   ├── persist.sh            # backup / dump-live-to-config / restore 3개 함수 (~150줄)
│   ├── rule.sh               # INPUT/DOCKER-USER/OUTPUT 규칙 편집
│   ├── team.sh               # ipset 팀 관리
│   ├── rollback.sh           # 백업 목록 UI + 복원
│   ├── safety.sh             # SSH 경고, 60초 타이머, ESTABLISHED,RELATED 감지
│   └── bootstrap.sh          # 첫 실행 import
└── config/                   # 자동 생성
    ├── iptables.rules        # iptables-save 포맷 (스코프 필터됨)
    ├── ipsets.rules          # ipset save 포맷 (관리 대상만)
    └── backups/
        └── YYYY-MM-DD_HH-MM-SS.tar.gz × 최근 20개
```

**삭제되는 기존 파일/디렉토리**

- `lib/bundle.sh` (379줄) — migration 스코프 제외
- `lib/sync.sh` (531줄) — 자동 저장 모델로 불필요
- `lib/preflight.sh` (109줄) — 최소 체크만 `common.sh`에 병합
- `lib/validators.sh` (489줄) — 대부분 커스텀 검증 로직, 삭제하고 커널 에러 메시지로 대체
- `config/teams/*.conf` — ipset 네이티브 comment로 대체
- `MIGRATION.md`, `examples/SCENARIOS.md` — 해당 기능 삭제되므로 같이 제거/축소

## 10. 핵심 함수 시그니처 (구현 시 참조)

### `lib/scope.sh`

```bash
scope_filter_iptables      # stdin: iptables-save 전체 → stdout: 우리 스코프만
scope_filter_ipset         # stdin: ipset save 전체 + "managed 목록 파일" → stdout: 관리 대상만
scope_is_our_chain CHAIN   # INPUT/OUTPUT/DOCKER-USER 이면 0, else 1
```

### `lib/persist.sh`

```bash
persist_backup                    # config/ → backups/<ts>.tar.gz, rotate
persist_dump_live_to_config       # live → config/*.rules
persist_restore_from_config       # config → live (ipset 먼저, iptables 나중, --noflush)
persist_rollback_to TIMESTAMP     # backup에서 복원
persist_transaction FUNC ARGS...  # backup + FUNC ARGS + (실패 시 롤백 / 성공 시 dump)
```

모든 변경 함수는 `persist_transaction`으로 감싸서 호출.

### `lib/safety.sh`

```bash
safety_check_ssh_block RULE         # SSH 차단 위험 감지
safety_arm_confirm_timer SECONDS    # 60초 타이머 (미확인 시 롤백)
safety_check_established            # INPUT에 ESTABLISHED,RELATED 존재 여부
```

## 11. 에러 처리 방침

- `iptables`, `ipset`, `iptables-restore` 등 바이너리가 반환한 에러는 **그대로 사용자에게 노출**. 자체 포장/번역 없음.
- 트랜잭션 중 어느 단계라도 실패하면 **자동 롤백 + exit 1**. 반쯤 적용된 상태를 남기지 않음.
- 로그는 stderr로만. 파일 로깅 없음 (필요 시 나중에 추가).

## 12. 테스트 방침

본 재작성에서는 자동화된 테스트 프레임워크를 도입하지 않는다. 대신 **구현 완료 시 수동 smoke test 체크리스트**를 작성해서 README나 구현 PR에 포함한다:

- 첫 실행 bootstrap
- 팀 생성 / IP 추가 / IP 삭제
- INPUT 허용 추가 / 차단 추가 / 삭제
- OUTPUT 차단 추가 / 삭제
- DOCKER-USER 규칙 추가 (Docker 있는/없는 환경 각각)
- 변경 후 롤백
- 동시 실행 시 flock 동작

자동화는 이후 필요해지면 추가.

## 13. 예상 규모

- 현재: 4,315줄
- 재작성 후 목표: **~1,300줄 내외**
- 특히 `persist.sh`: 945줄 → ~150줄

## 14. 이 스펙이 다루지 않는 것 (명시적 non-goals)

- 서버 이전 (migration), export/import 번들
- live ↔ config 양방향 sync
- OUTPUT default policy 변경, OUTPUT ACCEPT 규칙 관리
- FORWARD / nat / mangle
- ipset `hash:ip`, `hash:mac`, bitmap 등 non-hash:net 타입
- 자동화 테스트 스위트
- dry-run / `--apply=no` 모드
- 로그 파일, 감사(audit) 기능
- 멀티 사용자 권한 모델
