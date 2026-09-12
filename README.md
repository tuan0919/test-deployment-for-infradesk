# Test Deployment for InfraDesk

App mẫu production-like: **Node.js CRUD + PostgreSQL**, runtime data **bind-mount ra host** (`DATA_ROOT`), tách pipeline YAML theo việc cần làm.

## Runtime layout (host)

```text
/var/lib/test-deployment-for-infradesk/     # DATA_ROOT
  postgres/          # PostgreSQL data files
  uploads/           # file runtime (mẫu)
  backups/
    20260911T013000Z/
      database.sql
      uploads.tgz
      manifest.txt
```

Image/container có thể đổi (`v1` → `v2`); **data giữ trên host** qua mount.

## App

- API: `GET/POST /api/notes`, `DELETE /api/notes/:id`, `GET /api/health`, `GET /api/version`
- UI tĩnh: form CRUD ghi chú + hiển thị `APP_VERSION` / `IMAGE_TAG`

```bash
npm ci
npm test
```

## Docker

Compose production: [`deploy/docker-compose.yml`](deploy/docker-compose.yml)  
Copy env: `cp deploy/.env.example deploy/.env` và chỉnh `DATA_ROOT`, `POSTGRES_PASSWORD`.

## Pipeline YAML (một repo, nhiều file)

Đăng ký **3 pipeline** trên InfraDesk, cùng repo Git, khác `yamlPath`:

| File | Mục đích |
|------|----------|
| [`deploy.yaml`](deploy.yaml) | build image → chạy đồng thời unit test, pseudo performance test, pseudo integration test → deploy thủ công |
| [`backup.yaml`](backup.yaml) | backup thủ công: `pg_dump` + tar `uploads/` → `BACKUP_ROOT/$BACKUP_ID` |
| [`restore.yaml`](restore.yaml) | restore thủ công từ `BACKUP_ID`, rồi `compose up` |

### Biến quan trọng

| Biến | Ý nghĩa |
|------|---------|
| `IMAGE_TAG` | Tag image release (`v2.0.0`) |
| `DATA_ROOT` | Thư mục host chứa postgres + uploads |
| `BACKUP_ROOT` | Thư mục host chứa backup |
| `BACKUP_ID` | Tên thư mục backup (restore); backup tự sinh nếu bỏ trống |
| `POSTGRES_PASSWORD` | Secret pipeline (CI credential) |
| `REGISTRY_PASSWORD` | Secret registry (deploy và restore) |

### Flow release / rollback gợi ý

1. **Release v2:** chạy pipeline `deploy.yaml` với `IMAGE_TAG=v2.0.0`
2. **Trước upgrade:** chạy `backup.yaml` (lưu `BACKUP_ID` từ log/manifest)
3. **Rollback data + app v1:** chạy `restore.yaml` với `BACKUP_ID=...`, sau đó deploy lại `IMAGE_TAG=v1.0.0` (hoặc ghi `IMAGE_TAG` trong manifest backup)

Scripts: [`deploy/scripts/backup.sh`](deploy/scripts/backup.sh), [`deploy/scripts/restore.sh`](deploy/scripts/restore.sh).
