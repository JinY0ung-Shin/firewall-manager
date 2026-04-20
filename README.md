# fw - Interactive Firewall Manager (v2.0)

`fw`는 `iptables`와 `ipset`을 잘 몰라도 방화벽을 안전하게 운영할 수 있게 해주는 **대화형 CLI 도구**입니다.

관리 범위는 실무에서 자주 건드리는 **`INPUT`**(들어오는 트래픽), **`DOCKER-USER`**(컨테이너로 가는 트래픽), **`OUTPUT`**(나가는 트래픽 — 차단 전용), 그리고 **`ipset(hash:net)`** 기반 팀 관리에 집중합니다.

## 핵심 목표

1. `iptables` / `ipset` 문법을 몰라도 메뉴 기반으로 안전하게 운영할 수 있게 한다.
2. 자동 저장 + 타임스탬프 백업으로 **언제든 되돌릴 수 있게** 한다.

## 이런 상황에 적합합니다

- 운영자가 `iptables` 문법을 외우지 않고도 허용/차단 규칙을 관리해야 할 때
- 허용 대상 IP를 팀 단위(`ipset`)로 관리하고 싶을 때
- 특정 외부 주소(사내 프록시 등)로 **나가는 트래픽을 선택적으로 차단**해야 할 때
- 변경 후 문제가 생기면 최근 상태로 **빠르게 롤백**하고 싶을 때

## 요구사항

- Linux (iptables, ipset 설치 필요)
- root 권한 (sudo)
- Bash 4+

```bash
# Ubuntu/Debian
sudo apt install iptables ipset
```

## 사용 방식

레포 디렉터리에서 직접 실행하는 것을 기준으로 합니다. 시스템 경로에 설치하지 않고, `git pull` 후 같은 폴더에서 `./fw`를 실행하면 됩니다.

```bash
git pull
sudo ./fw
```

설정 파일은 레포 안의 `./config/` 를 사용합니다. 첫 실행 시 현재 서버의 `INPUT` / `DOCKER-USER` / `OUTPUT` 상태와 기존 `ipset` 목록을 스캔해서 관리 대상을 고르게 합니다. **live 상태는 첫 실행에서 변경하지 않습니다.**

## 사용법

### 대화형

```bash
sudo ./fw
```

```
  +======================================+
  |       Firewall Manager v2.0.0        |
  +======================================+

    1) 규칙 관리
    2) 팀 관리 (ipset)
    3) 롤백 (백업에서 복원)
    4) 현재 상태 보기
    0) 종료
```

### 비대화형

```bash
sudo ./fw status          # 현재 상태 표시
sudo ./fw rollback        # 백업 목록 표시
sudo ./fw rollback 2      # 2번째 최신 백업으로 복원
sudo ./fw --help          # 도움말
```

## 저장/복원 모델 — 자동 저장

별도의 `save` / `load` 명령이 없습니다. 대신:

- 메뉴로 규칙/팀을 **바꾸면** 즉시 live에 적용되고, 변경 후 live 상태가 `config/` 로 덤프됩니다.
- 모든 변경 **직전에** `config/backups/<timestamp>.tar.gz` 가 자동 생성됩니다 (최근 20개 유지).
- 되돌리고 싶으면 메뉴의 "롤백" 에서 원하는 백업을 선택합니다.
- 실패 시 자동으로 백업에서 복원됩니다 (트랜잭셔널).

## 주요 기능

### 규칙 관리
- **INPUT / DOCKER-USER**: 소스 기반 허용/차단 추가
- **OUTPUT**: 목적지 기반 **차단만** 추가 (자기-차단 방지)
- 소스/목적지: 단일 IP, CIDR, 팀(ipset), 전체
- 규칙 삭제는 현재 live에서 목록을 보여주고 선택

### 팀 관리 (ipset)
- 팀 생성/삭제, 멤버 추가/제거
- 멤버 추가 시 **설명(comment) 필수** — ipset 네이티브 comment로 저장
- 팀별 `.conf` 파일 없음: `config/ipsets.rules` 하나로 관리

### 안전장치
- SSH 차단 가능성 있는 규칙 추가 시 경고
- DROP/REJECT 추가 후 **60초 안전 타이머** — 미확인 시 자동 롤백
- `ESTABLISHED,RELATED` 누락 감지 + 자동 삽입 제안
- 변경 직전 자동 백업 + 실패 시 자동 롤백
- `flock` 으로 동시 실행 방지

### 롤백
- 최근 20개 백업에서 선택
- 복원 직전 현재 상태도 `pre-rollback` 백업으로 저장

## 범위와 철학

- `INPUT`, `DOCKER-USER`, `OUTPUT`(차단만), `ipset(hash:net)` 만 관리합니다.
- `FORWARD`, `nat`, `mangle`, `DOCKER` 등 Docker 자동 생성 체인은 **읽지도 쓰지도 않습니다**.
- 커스텀 파싱 대신 `iptables-save` / `ipset save` **네이티브 포맷**을 그대로 사용합니다.
- 복원 시 `iptables-restore --noflush` 로 **파일에 선언된 체인만** 비우고 적용하므로 다른 체인에 영향 없습니다.

## 디렉토리 구조

```
firewall-manager/
├── fw                   # 엔트리포인트
├── SMOKE_TEST.md        # 수동 검증 체크리스트
├── examples/
│   └── fw-restore.service
├── lib/
│   ├── common.sh        # 색상, 로그, 메뉴, flock
│   ├── scope.sh         # iptables-save/ipset save 필터
│   ├── persist.sh       # backup/dump/restore/transaction
│   ├── safety.sh        # SSH 경고, 60초 타이머
│   ├── bootstrap.sh     # 첫 실행 import
│   ├── team.sh          # ipset 팀 관리
│   ├── rule.sh          # iptables 규칙 편집
│   ├── rollback.sh      # 백업 목록 + 복원
│   └── status.sh        # 상태 요약
├── docs/
│   └── superpowers/     # 재작성 설계/구현 계획
└── config/              # (자동 생성)
    ├── iptables.rules   # iptables-save 네이티브 포맷
    ├── ipsets.rules     # ipset save 네이티브 포맷
    └── backups/         # 타임스탬프 tar.gz × 최근 20개
```

## 예시

- 부팅 시 자동 복원이 필요하면 [examples/fw-restore.service](./examples/fw-restore.service) 예시를 참고할 수 있습니다.
- 새 버전 동작 검증은 [SMOKE_TEST.md](./SMOKE_TEST.md) 를 따라가면 됩니다.

## 라이선스

MIT
