# Test Deployment for InfraDesk

Frontend tĩnh hiển thị phiên bản đang chạy. Dùng để thử pipeline InfraDesk: build image → unit test → deploy trên cùng máy runner.

Phiên bản trên trang lấy từ biến build `APP_VERSION` (pipeline gán bằng `IMAGE_TAG`).

## Chạy unit test

```bash
npm ci
npm test
```

## Pipeline

Định nghĩa YAML nằm ở repo trung tâm [`infradesk-pipelines`](https://github.com/SPG-VN/infradesk-pipelines), file `pipelines/test-deployment.yml`.
