# Migration Guide

`fw`를 사용해서 한 서버의 방화벽 설정을 다른 서버로 옮길 때 권장하는 절차입니다.

이 가이드는 다음 범위를 기준으로 작성되어 있습니다.

- `INPUT` 체인
- `DOCKER-USER` 체인
- `ipset hash:net` 팀 설정

## 0. 시작 전 확인

- 두 서버 모두 `iptables`, `ipset` 이 설치되어 있어야 합니다.
- 새 서버도 같은 레포 디렉터리에서 `sudo ./fw ...` 방식으로 실행합니다.
- Docker 서버가 아니면 `DOCKER-USER` 규칙은 그대로 복원되지 않을 수 있습니다.
- SSH 포트가 다르면 적용 전에 허용 규칙을 다시 확인하는 것이 안전합니다.

필요 패키지 예시:

```bash
sudo apt install iptables ipset
```

## 1. 기존 서버에서 현재 상태 저장

먼저 live 상태를 `config/`에 저장합니다.

```bash
sudo ./fw save
```

현재 저장 상태를 확인하고 싶다면:

```bash
sudo ./fw status
```

## 2. 이전 번들 생성

저장된 `config/` 상태를 tar.gz 번들로 만듭니다.

```bash
sudo ./fw export ./fw-bundle.tar.gz
```

이 번들에는 보통 아래 정보가 포함됩니다.

- `config/iptables.rules`
- `config/iptables-full.rules`
- `config/teams/*.conf`

## 3. 번들을 새 서버로 전달

예시:

```bash
scp ./fw-bundle.tar.gz user@new-server:/path/to/firewall-manager/
```

새 서버에도 이 레포가 있어야 합니다.

```bash
git pull
```

## 4. 새 서버에서 가져오기

새 서버에서 레포 디렉터리로 이동한 뒤 번들을 가져옵니다.

```bash
cd /path/to/firewall-manager
sudo ./fw import ./fw-bundle.tar.gz
```

이 단계는 `config/`만 바꾸고, 아직 live 방화벽에는 적용하지 않습니다.

## 5. 적용 전 사전 점검

```bash
sudo ./fw preflight
```

이 단계에서 꼭 확인할 것:

- `iptables`, `ipset`, `tar` 가 설치되어 있는지
- 저장된 규칙 파일이 정상적으로 들어왔는지
- `DOCKER-USER` 규칙이 있는데 대상 서버에 체인이 없는지
- SSH 접근에 필요한 규칙 검토가 필요한지

## 6. 새 서버에 적용

점검이 끝났으면 저장된 설정을 live 방화벽에 적용합니다.

```bash
sudo ./fw load
```

`load` 는 검증 실패 시 이전 live 상태로 롤백하도록 설계돼 있습니다.

이미 번들 가져오기와 적용을 한 번에 하고 싶다면:

```bash
sudo ./fw import ./fw-bundle.tar.gz --apply
```

## 7. 적용 후 확인

```bash
sudo ./fw status
```

필요하면 다음도 함께 확인합니다.

```bash
sudo iptables -S INPUT
sudo iptables -S DOCKER-USER
sudo ipset list -n
```

## 권장 운영 팁

### 새 서버 원래 상태를 보관하고 싶을 때

새 서버의 현재 상태도 먼저 저장해 두면 비교나 복구가 쉽습니다.

```bash
sudo ./fw save
sudo ./fw export ./before-migration.tar.gz
```

### 번들 없이 `config/` 디렉터리만 옮기고 싶을 때

가능은 하지만, 운영 실수 방지를 위해 번들 방식이 더 안전합니다.

```bash
scp -r ./config user@new-server:/path/to/firewall-manager/
```

이후 새 서버에서:

```bash
sudo ./fw preflight
sudo ./fw load
```

### 대상 서버에서 처음 실행하는 경우

`fw`는 `config/iptables.rules` 가 없을 때 현재 live `iptables` 상태를 자동으로 bootstrap 할 수 있습니다.
하지만 서버 이전이 목적이라면, 처음 interactive 메뉴에 들어가기 전에 먼저 `import` 를 하는 쪽이 더 명확합니다.

권장 순서:

```bash
sudo ./fw import ./fw-bundle.tar.gz
sudo ./fw preflight
sudo ./fw load
```

## 빠른 명령 요약

기존 서버:

```bash
sudo ./fw save
sudo ./fw export ./fw-bundle.tar.gz
```

새 서버:

```bash
cd /path/to/firewall-manager
git pull
sudo ./fw import ./fw-bundle.tar.gz
sudo ./fw preflight
sudo ./fw load
```
