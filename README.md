# fw - Interactive Firewall Manager

`fw`는 `iptables`와 `ipset`을 잘 몰라도 방화벽을 쉽게 관리하고,
현재 서버의 방화벽 설정을 다른 서버로 편하게 옮길 수 있게 해주는
**대화형 CLI 도구**입니다.

관리 범위는 실무에서 자주 건드리는 `INPUT`, `DOCKER-USER`, `ipset(hash:net)`에 집중합니다.

## 핵심 목표

1. `iptables` / `ipset` 명령을 몰라도 메뉴 기반으로 안전하게 운영할 수 있게 한다.
2. live 방화벽 상태를 파일로 저장하고, 다른 서버에 쉽게 복원하거나 동기화할 수 있게 한다.

## 이런 상황에 적합합니다

- 운영자가 `iptables` 문법을 외우지 않고도 허용/차단 규칙을 관리해야 할 때
- 허용 대상 IP를 팀 단위(`ipset`)로 관리하고 싶을 때
- 현재 서버의 방화벽 상태를 새 서버로 이전해야 할 때
- 사람이 직접 `iptables`, `ipset`을 수정한 뒤 파일 상태와 다시 맞춰야 할 때

## 요구사항

- Linux (iptables, ipset 설치 필요)
- root 권한 (sudo)
- Bash 4+

```bash
# Ubuntu/Debian
sudo apt install iptables ipset
```

## 설치

### 로컬 실행

레포 그대로 실행하면 `./config/`를 사용합니다.

```bash
sudo ./fw
```

### 시스템 전체 설치

설치형으로 쓰면 실행 파일은 `/usr/local/bin/fw`, 설정은 `/etc/fw`를 기본으로 사용합니다.

```bash
sudo ./install.sh
sudo fw --help
```

현재 레포의 저장된 설정까지 함께 옮기려면:

```bash
sudo ./install.sh --copy-config
```

## 사용법

```bash
sudo ./fw
```

```
  +==========================================+
  |       Firewall Manager v1.0.0          |
  +==========================================+

    1)  규칙 관리 (iptables)
    2)  팀 관리 (ipset)
    3)  저장 / 불러오기
    4)  동기화 (live ↔ config)
    5)  사전 점검 (restore 전)
    6)  현재 상태 보기

    0)  종료
```

### 비대화형 모드

```bash
sudo ./fw status       # 상태 보기
sudo ./fw preflight    # 복원/이전 전 사전 점검
sudo ./fw save         # 현재 규칙 저장
sudo ./fw load         # 저장된 규칙 불러오기
sudo ./fw sync         # 동기화 메뉴
sudo ./fw export       # 이전용 번들 생성
sudo ./fw import FILE  # 이전 번들 가져오기
sudo ./fw --help       # 도움말
```

## 서버 이전 흐름

다른 서버로 방화벽 설정을 옮길 때는 보통 아래 흐름으로 사용합니다.

1. 기존 서버에서 현재 상태를 저장합니다.

```bash
sudo ./fw save
```

2. 번들을 만들거나 `config/` 디렉터리를 새 서버로 복사합니다.

```bash
sudo ./fw export ./fw-bundle.tar.gz
scp -r ./config user@new-server:/path/to/firewall-manager/
```

3. 새 서버에서 저장된 설정을 적용합니다.

```bash
sudo fw import ./fw-bundle.tar.gz
sudo fw preflight
sudo fw load
```

이미 점검을 마쳤다면 한 번에 적용할 수도 있습니다.

```bash
sudo fw import ./fw-bundle.tar.gz --apply
```

직접 `iptables`나 `ipset`을 수정한 뒤 파일 상태와 비교해서 맞추고 싶다면
`sudo ./fw sync`로 `live ↔ config` 동기화를 진행할 수 있습니다.

## 서버 이전 전 체크리스트

- 대상 서버에도 `iptables`, `ipset`이 설치되어 있어야 합니다.
- 이 도구는 `INPUT`, `DOCKER-USER`, `ipset(hash:net)` 중심으로만 복원합니다.
- `DOCKER-USER`는 Docker가 실행 중인 서버에서만 복원 가능합니다.
- SSH 포트가 서버마다 다르면 적용 전에 허용 규칙을 한 번 더 확인하는 것이 안전합니다.
- UFW, Docker, 배포판 기본 규칙처럼 서버 환경에 따라 달라지는 항목은 복원 후 검토가 필요할 수 있습니다.

## 주요 기능

### 쉽게 쓰는 방화벽 관리
- INPUT / DOCKER-USER 체인 규칙 추가·삭제
- 소스: IP, CIDR, 팀(ipset), 전체
- 단계별 위저드로 안내
- 팀(ipset) 기반으로 "허용 대상 묶음"을 추상화해서 관리 가능

### 팀 관리 (ipset)
- 팀 생성·삭제, 멤버 추가·제거
- IP 추가 시 **설명(comment) 필수** — 누구의 IP인지 항상 식별 가능

### 서버 이전을 위한 저장 / 복원
- 현재 iptables / ipset 상태를 `./config/` 기준으로 정리해 저장
- 백업 생성·복원 (최근 10개 자동 유지)
- tar.gz 기반 이전 번들 export/import 지원
- 트랜잭셔널 로드: 실패 시 자동 롤백
- 다른 서버에서 `config/`만 있으면 같은 기준으로 복원 가능

### 동기화
- `iptables`나 `ipset`을 직접 수정한 경우 **live ↔ config 차이를 감지**
- 방향 선택: live → config 또는 config → live

### 사전 점검
- 복원 전 필수 명령, 저장된 규칙 파일, 팀 파일, DOCKER-USER 체인 상태를 확인
- 대상 서버에서 바로 적용해도 되는지 빠르게 판단 가능

### 안전장치
- SSH 접속 차단 규칙 추가 시 경고
- DROP/REJECT 규칙 추가 후 **60초 안전 타이머** (미확인 시 자동 제거)
- ESTABLISHED,RELATED 규칙 누락 감지

## 예시

- 실사용 시나리오는 [examples/SCENARIOS.md](/home/jinyoung/firewall-manager/examples/SCENARIOS.md) 에 정리했습니다.
- 부팅 시 자동 복원이 필요하면 [examples/fw-restore.service](/home/jinyoung/firewall-manager/examples/fw-restore.service) 예시를 참고할 수 있습니다.

## 범위와 철학

- 이 도구는 모든 체인을 추상화하지 않고 `INPUT`, `DOCKER-USER` 중심으로 다룹니다.
- 복잡한 룰셋 전체를 자동 모델링하기보다, 운영자가 자주 바꾸는 영역을 쉽게 다루는 데 집중합니다.
- `ipset` 팀 메타데이터를 파일로 함께 관리해서 서버 간 이전 시 의미를 잃지 않도록 합니다.

## 디렉토리 구조

```
firewall-manager/
├── fw                  # 메인 스크립트 (엔트리포인트)
├── install.sh          # 시스템 전체 설치 스크립트
├── examples/
│   ├── SCENARIOS.md    # 실사용 시나리오 예시
│   └── fw-restore.service
├── lib/
│   ├── bundle.sh       # 이전 번들 export/import
│   ├── common.sh       # 색상, 로깅, 메뉴, 프롬프트
│   ├── preflight.sh    # 복원 전 사전 점검
│   ├── validators.sh   # 입력 검증, SSH 충돌 감지
│   ├── rule.sh         # iptables 규칙 관리
│   ├── team.sh         # ipset 팀 관리
│   ├── persist.sh      # 저장/불러오기/백업/복원
│   ├── status.sh       # 상태 대시보드
│   └── sync.sh         # live ↔ config 동기화
└── config/             # (자동 생성) 규칙·팀 설정 저장
    ├── iptables.rules
    ├── teams/*.conf
    └── backups/
```

## 라이선스

MIT
