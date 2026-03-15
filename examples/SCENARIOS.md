# Example Scenarios

## 1. Office IP Allowlist

Use `팀 관리 (ipset)` to create a team such as `office`.
Add the office public IPs with comments so you always know who owns each address.
Then add an `INPUT` rule that allows SSH only from `team:office`.

## 2. Team-Based SSH Access

Create teams like `backend`, `ops`, or `vendor-temp`.
Add each member IP with a descriptive comment.
Use rules that allow port `22` from a selected team instead of adding many separate IP rules.

## 3. Migrate to a New Docker Host

On the source server:

```bash
sudo ./fw save
sudo ./fw export ./fw-bundle.tar.gz
```

On the target server:

```bash
git pull
sudo ./fw import ./fw-bundle.tar.gz
sudo ./fw preflight
sudo ./fw load
```

If the target server uses Docker, make sure the `DOCKER-USER` chain exists before restore.
