import { loadConfig, configProblems, configWarnings, configuredProviderIds } from './config.js';
import { createRedactor, secretsOf } from './redact.js';
import { createServer } from './app.js';

const config = loadConfig();
const problems = configProblems(config);
for (const p of problems) console.warn(`[config] ${p}`);
for (const w of configWarnings(config)) console.warn(`[config] warning: ${w}`);

const redact = createRedactor(secretsOf(config));
const server = createServer({ config, logger: (line) => console.log(redact(line)) });
server.listen(config.port, '0.0.0.0', () => {
  console.log(`almus-backend listening on port ${config.port} (providers configured: ${configuredProviderIds(config).join(', ') || 'none'})`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
