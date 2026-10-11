import { loadConfig, configProblems } from './config.js';
import { createServer } from './app.js';

const config = loadConfig();
const problems = configProblems(config);
for (const p of problems) console.warn(`[config] ${p}`);

const server = createServer({ config, logger: (line) => console.log(line) });
server.listen(config.port, '0.0.0.0', () => {
  console.log(`almus-backend listening on port ${config.port} (model: ${config.geminiModel})`);
});

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 5000).unref();
  });
}
