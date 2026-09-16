import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['test/**/*.test.ts'],
    setupFiles: ['test/setup.ts'],
    pool: 'forks',
    testTimeout: 30_000,
    // These are integration-style tests against a real shared Postgres database.
    // Running test files in parallel causes cross-file TRUNCATE races (FK violations,
    // deadlocks, flaky counts), so force sequential execution across files.
    fileParallelism: false,
  },
});
