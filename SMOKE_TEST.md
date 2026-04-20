# Smoke Test — firewall-manager v2.0

재작성 후 실환경(격리된 VM이나 컨테이너 권장)에서 한 번씩 밟는 수동 체크리스트입니다. 각 항목이 모두 기대대로 동작하면 PR/릴리스 OK로 봅니다.

## 준비

- 리눅스 VM 또는 `--privileged` 컨테이너 (iptables/ipset 실행 가능 환경)
- root 접근
- `iptables`, `ipset`, `flock`, `tar` 설치

## 체크리스트

### 1. 첫 실행 bootstrap

- [ ] `config/` 를 삭제한 상태에서 `sudo ./fw status` 실행
- [ ] bootstrap 메시지가 뜨고 ipset 선택 체크리스트가 나타남
- [ ] 선택 후 `config/iptables.rules`, `config/ipsets.rules`, `config/backups/*_initial.tar.gz` 생성됨
- [ ] live iptables 규칙은 **변경 없음** (bootstrap 전후 `iptables -S` 비교)

### 2. 팀 생성 / IP 추가 / IP 삭제

- [ ] 메뉴 → 팀 관리 → 팀 생성 → 이름 `team_smoke` → 완료
- [ ] `ipset list team_smoke` 로 `comment` 옵션이 포함되어 생성됐는지 확인
- [ ] 멤버 추가: `10.0.0.1`, 설명 `"smoke-a"` → 성공
- [ ] 설명을 빈 문자열로 추가 시도 → 거부됨
- [ ] 멤버 삭제 → `10.0.0.1` 사라짐
- [ ] `config/ipsets.rules` 에 변경이 즉시 반영되어 있음

### 3. INPUT 허용 추가

- [ ] 메뉴 → 규칙 관리 → INPUT 허용 추가 → 팀 `team_smoke` → 모든 포트
- [ ] `iptables -S INPUT` 에 `-m set --match-set team_smoke src -j ACCEPT` 존재
- [ ] `config/iptables.rules` 에 해당 라인 존재

### 4. INPUT 차단 추가 (SSH 경고 & 60초 타이머)

- [ ] 단일 IP `203.0.113.99`, 포트 제한 없음, 차단 → SSH 경고 뜸
- [ ] 확인 후 적용 → 60초 타이머 시작
- [ ] 60초 안에 엔터 → 확정 메시지
- [ ] 다시 다른 DROP 규칙 추가 후 60초 대기 → 자동 롤백 확인

### 5. OUTPUT 차단 추가

- [ ] OUTPUT 차단 추가 → destination `10.50.0.0/16`, TCP 8080, DROP
- [ ] `iptables -S OUTPUT` 에 해당 라인 존재
- [ ] `iptables -S OUTPUT` 의 기존 ACCEPT 규칙이 **그대로 보존**되어 있음

### 6. DOCKER-USER (Docker 있는 환경)

- [ ] Docker 실행 중인 환경에서 DOCKER-USER 허용 규칙 추가 → 성공
- [ ] Docker 없는 환경에서 동일 시도 → iptables 에러가 사용자에게 그대로 노출됨

### 7. 변경 후 롤백

- [ ] 몇 개 규칙 추가한 상태에서 `sudo ./fw rollback` → 백업 목록 표시
- [ ] `*_initial.tar.gz` 선택 → 복원 → `iptables -S` 가 처음과 동일
- [ ] 롤백 전 현재 상태는 `pre-rollback` 백업으로 저장되었는지 확인

### 8. 비대화형 커맨드

- [ ] `sudo ./fw status` → 상태 요약 출력
- [ ] `sudo ./fw rollback 2` → 2번째 최신 백업으로 복원

### 9. 동시 실행 flock

- [ ] 터미널 A에서 `sudo ./fw` 실행 (메뉴 대기 상태)
- [ ] 터미널 B에서 `sudo ./fw` 시도 → "다른 fw 인스턴스 실행 중" 에러로 즉시 종료

### 10. 복원 순서 (ipset → iptables)

- [ ] `team_smoke` 를 참조하는 INPUT 규칙이 있는 상태에서
- [ ] `ipset destroy team_smoke` 를 수동으로 실행 (도구 밖)
- [ ] `sudo ./fw rollback` → 최신 `pre-*` 백업으로 복원
- [ ] **복원 성공** (ipset이 먼저 복구되므로 iptables 규칙이 유효해짐)
