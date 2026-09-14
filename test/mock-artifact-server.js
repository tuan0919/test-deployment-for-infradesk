import http from 'node:http';

// Fixtures for testing
const FIXTURES = {
  // Case 1: Valid manifest
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-test-success-001',
      commitSha: 'de8586a1234567890abcdef1234567890abcdef',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
    }, null, 2),
  },
  // Case 2: 404 Not Found
  '40444444-4444-4444-4444-444444444444': {
    status: 404,
    body: JSON.stringify({ error: 'Artifact not found' }),
  },
  // Case 3: Timeout (handled dynamically with delay)
  'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb': {
    delayMs: 3000,
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-timeout',
      commitSha: 'timeout-sha',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
    }),
  },
  // Case 4: Used for checksum mismatch (served valid, client sends wrong sha)
  'cccccccc-cccc-cccc-cccc-cccccccccccc': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-checksum-mismatch',
      commitSha: 'checksum-sha',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
    }),
  },
  // Case 5a: Malformed JSON (syntax error)
  '55555555-5555-5555-5555-000000000001': {
    status: 200,
    body: '{ malformed json syntax error: true, ',
  },
  // Case 5b: Missing snapshotId
  '55555555-5555-5555-5555-000000000002': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      commitSha: 'missing-snapshot-id',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
    }),
  },
  // Case 5c: Empty snapshotId
  '55555555-5555-5555-5555-000000000003': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: '',
      commitSha: 'empty-snapshot-id',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
    }),
  },
  // Case 5d: Wrong schemaVersion (e.g. 2)
  '55555555-5555-5555-5555-000000000004': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 2,
      snapshotId: 'snap-wrong-version',
      commitSha: 'wrong-version',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
    }),
  },
  // Case 5e: Missing required string fields (database, createdAt)
  '55555555-5555-5555-5555-000000000005': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-missing-fields',
      commitSha: 'missing-fields',
    }),
  },
  // Case 5f: Prohibited credentials/command fields
  '55555555-5555-5555-5555-000000000006': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-with-password',
      commitSha: 'has-secrets',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
      password: 'super-secret-password-should-not-exist',
    }),
  },
  // Case 5g: Prohibited nested credentials/command fields
  '55555555-5555-5555-5555-000000000007': {
    status: 200,
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-with-nested-token',
      commitSha: 'has-nested-secrets',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
      extra: {
        apiToken: 'super-secret-token-nested',
      },
    }),
  },
  // Case 7: File size limit exceeded (> 256 KiB = 262144 bytes)
  '77777777-7777-7777-7777-777777777777': {
    status: 200,
    // 300 KiB payload
    body: JSON.stringify({
      schemaVersion: 1,
      snapshotId: 'snap-oversized',
      commitSha: 'oversized',
      database: 'app',
      createdAt: '2026-09-14T03:00:00Z',
      padding: 'x'.repeat(300 * 1024),
    }),
  },
};

const server = http.createServer((req, res) => {
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const match = parsedUrl.pathname.match(/^\/api\/pipelines\/([^/]+)\/runs\/([^/]+)\/artifacts\/download$/);

  if (!match) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Endpoint not found' }));
  }

  const [, pipelineId, runId] = match;
  const job = parsedUrl.searchParams.get('job');
  const artifactPath = parsedUrl.searchParams.get('path');

  // Verify expected query parameters
  if (job !== 'backup_runtime' || artifactPath !== 'output/backup-reference.json') {
    res.writeHead(400, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Invalid query parameters' }));
  }

  const fixture = FIXTURES[runId];
  if (!fixture) {
    res.writeHead(404, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ error: 'Run not found' }));
  }

  const sendResponse = () => {
    res.writeHead(fixture.status, { 'Content-Type': 'application/json' });
    res.end(fixture.body);
  };

  if (fixture.delayMs) {
    setTimeout(sendResponse, fixture.delayMs);
  } else {
    sendResponse();
  }
});

server.listen(0, '127.0.0.1', () => {
  const address = server.address();
  console.log(`PORT=${address.port}`);
});

process.on('SIGTERM', () => {
  server.close(() => {
    process.exit(0);
  });
});
