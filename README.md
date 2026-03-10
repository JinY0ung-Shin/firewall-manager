# fw - Interactive Firewall Manager

iptables + ipset을 **대화형 메뉴**로 관리하는 CLI 도구.

INPUT / DOCKER-USER 체인과 ipset 팀을 누구나 쉽게 관리할 수 있습니다.

## 요구사항

- Linux (iptables, ipset 설치 필요)
- root 권한 (sudo)
- Bash 4+

```bash
# Ubuntu/Debian
sudo apt install iptables ipset
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
    5)  현재 상태 보기

    0)  종료
```

### 비대화형 모드

```bash
sudo ./fw status       # 상태 보기
sudo ./fw save         # 현재 규칙 저장
sudo ./fw load         # 저장된 규칙 불러오기
sudo ./fw sync         # 동기화 메뉴
sudo ./fw --help       # 도움말
```

## 주요 기능

### 규칙 관리
- INPUT / DOCKER-USER 체인 규칙 추가·삭제
- 소스: IP, CIDR, 팀(ipset), 전체
- 단계별 위저드로 안내

### 팀 관리 (ipset)
- 팀 생성·삭제, 멤버 추가·제거
- IP 추가 시 **설명(comment) 필수** — 누구의 IP인지 항상 식별 가능

### 저장 / 불러오기
- 현재 iptables 규칙을 `./config/`에 저장
- 백업 생성·복원 (최근 10개 자동 유지)
- 트랜잭셔널 로드: 실패 시 자동 롤백

### 동기화
- `iptables`나 `ipset`을 직접 수정한 경우 **live ↔ config 차이를 감지**
- 방향 선택: live → config 또는 config → live

### 안전장치
- SSH 접속 차단 규칙 추가 시 경고
- DROP/REJECT 규칙 추가 후 **60초 안전 타이머** (미확인 시 자동 제거)
- ESTABLISHED,RELATED 규칙 누락 감지

## 디렉토리 구조

```
firewall-manager/
├── fw                  # 메인 스크립트 (엔트리포인트)
├── lib/
│   ├── common.sh       # 색상, 로깅, 메뉴, 프롬프트
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
