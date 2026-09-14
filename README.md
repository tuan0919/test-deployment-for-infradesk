# Test Deployment for InfraDesk

App mẫu production-like: **Node.js CRUD + PostgreSQL**, runtime data **bind-mount ra host** (`DEPLOY_DIR`), tách pipeline YAML theo việc cần làm.

## Runtime layout (host)

```text
/var/lib/test-deployment-for-infradesk/     # DEPLOY_DIR
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
Copy env: `cp deploy/.env.example deploy/.env` và chỉnh `DEPLOY_DIR`, `POSTGRES_PASSWORD`.

## Pipeline YAML (một repo, nhiều file)

Đăng ký **3 pipeline** trên InfraDesk, cùng repo Git, khác `yamlPath`:

| File                           | Mục đích                                                                                                   |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| [`deploy.yaml`](deploy.yaml)   | build image → chạy đồng thời unit test, pseudo performance test, pseudo integration test → deploy thủ công |
| [`backup.yaml`](backup.yaml)   | backup thủ công: `pg_dump` + tar `uploads/` → snapshot lên Kopia → publish artifact `output/backup-reference.json` |
| [`restore.yaml`](restore.yaml) | restore thủ công: tải manifest artifact qua API → verify checksum/schema → restore snapshot Kopia → `compose up` |

### Biến cấu hình pipeline

| Biến                     | Loại    | Ý nghĩa                                                                 |
| ------------------------ | ------- | ----------------------------------------------------------------------- |
| `ARTIFACT_API_BASE`      | string  | Base URL của InfraDesk API runner truy cập được (vd: `http://infradesk:3000`) |
| `BACKUP_PIPELINE_ID`     | UUID    | ID của pipeline backup                                                 |
| `BACKUP_RUN_ID`          | UUID    | ID của run backup cụ thể cần restore (không dùng `latest`)              |
| `BACKUP_MANIFEST_SHA256` | hex64   | Checksum SHA256 mong đợi của file `output/backup-reference.json`        |
| `IMAGE_TAG`              | string  | Tag image release (`v2.0.0`)                                            |
| `DEPLOY_DIR`             | path    | Thư mục host chứa postgres + uploads                                    |
| `BACKUP_ROOT`            | path    | Thư mục host chứa staging/backup cục bộ                                 |
| `KOPIA_PASSWORD`         | secret  | Mật khẩu truy cập Kopia repository (CI credential)                      |
| `POSTGRES_PASSWORD`      | secret  | Mật khẩu database PostgreSQL (CI credential)                            |
| `REGISTRY_PASSWORD`      | secret  | Mật khẩu Docker registry (CI credential)                                |

### Hướng dẫn vận hành Backup & Restore

#### 1. Tạo bản backup (`backup.yaml`)
1. Chạy pipeline `backup.yaml`.
2. Job `backup_runtime` sẽ:
   - Dump PostgreSQL và nén thư mục `uploads/`.
   - Đẩy bản snapshot lên Kopia repository.
   - Tạo file manifest `output/backup-reference.json` chứa `schemaVersion: 1`, `snapshotId`, `commitSha`, `database`, `createdAt` (tuyệt đối không chứa mật khẩu/secret).
   - Publish manifest artifact lên InfraDesk với `expire_in: never`.

#### 2. Lấy thông tin Run UUID và SHA256
1. Vào trang chi tiết Run vừa chạy thành công của pipeline backup.
2. Lấy **`BACKUP_RUN_ID`**: sao chép UUID từ URL hoặc tiêu đề Run.
3. Lấy **`BACKUP_MANIFEST_SHA256`**: vào tab Artifacts (hoặc gọi `GET /api/pipelines/:pipelineId/runs/:runId/artifacts`), tìm `output/backup-reference.json` và sao chép chuỗi SHA256 (64 ký tự hex).

#### 3. Thực hiện Restore (`restore.yaml`)
1. Mở pipeline `restore.yaml`, chọn cấu hình biến:
   - `ARTIFACT_API_BASE`: URL của InfraDesk API.
   - `BACKUP_PIPELINE_ID`: UUID của pipeline backup.
   - `BACKUP_RUN_ID`: UUID của run backup đã chọn ở bước 2.
   - `BACKUP_MANIFEST_SHA256`: Checksum SHA256 đã lấy ở bước 2.
2. Tạo run mới. Do job `restore_runtime` có quy tắc `when: manual` và `allow_failure: false`, run sẽ ở trạng thái chờ duyệt (`Waiting for approval`).
3. Bấm **Play** để thực thi:
   - Runner dùng `download-backup-manifest.sh` tải manifest qua HTTP API từ run được chỉ định.
   - Tự động kiểm tra kích thước (<= 256 KiB), so khớp SHA256 với `BACKUP_MANIFEST_SHA256`, và validate JSON schema.
   - Nếu artifact hết hạn, bị xóa hoặc sai checksum: script dừng ngay lập tức (exit 1), không bao giờ chạm vào dữ liệu host.
   - Khi manifest hợp lệ, `restore.sh` kết nối Kopia, restore đúng `snapshotId` vào staging, dừng web container, import database, giải nén uploads, và khởi động lại dịch vụ qua `docker compose up -d`.

### Lưu ý quan trọng về Retention và Rerun

- **Chính sách Retention độc lập:**
  - Manifest artifact được lưu trong PostgreSQL của InfraDesk (quản lý theo artifact `expire_in` và việc xóa run).
  - Dữ liệu snapshot dung lượng lớn nằm trong Kopia repository và chịu sự quản lý retention của Kopia (maintenance/snapshot prune).
  - Hai retention này hoàn toàn độc lập: việc manifest artifact còn tồn tại không đảm bảo chắc chắn snapshot Kopia chưa bị prune. Script restore luôn xác thực sự tồn tại của snapshot trong Kopia trước khi thực hiện thao tác xóa dữ liệu cũ.
- **Hành vi Rerun:**
  - Nút Rerun trên InfraDesk hiện sử dụng bộ parameters cấu hình hiện tại của pipeline. Khi rerun một lần restore trước đó, operator phải kiểm tra và xác nhận lại `BACKUP_RUN_ID` và `BACKUP_MANIFEST_SHA256` để đảm bảo đang restore đúng snapshot mong muốn.
  - Khi rerun một run cũ trong lịch sử Git, hệ thống sẽ checkout commit tại thời điểm của run đó. Các commit cũ sẽ không có các script mới (`download-backup-manifest.sh`, `kopia-backup.sh`), do đó chỉ các run từ commit có script mới mới hỗ trợ flow tải manifest này.

### Scripts

- [`deploy/scripts/backup.sh`](deploy/scripts/backup.sh): Quy trình tạo bản dump và gọi Kopia upload.
- [`deploy/scripts/kopia-backup.sh`](deploy/scripts/kopia-backup.sh): Tương tác Kopia CLI để snapshot và xuất manifest JSON.
- [`deploy/scripts/download-backup-manifest.sh`](deploy/scripts/download-backup-manifest.sh): Tải và xác thực manifest artifact qua HTTP API.
- [`deploy/scripts/restore.sh`](deploy/scripts/restore.sh): Xác thực manifest, restore từ Kopia snapshot và khôi phục database/uploads.

