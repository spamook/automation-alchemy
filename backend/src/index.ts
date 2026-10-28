import express from 'express';
import cors from 'cors';
import metricsRouter from './routes/metrics.routes';
import { metricsMiddleware } from './prometheus';
import { logger, requestLogger } from './logger';

const app = express();
const PORT = process.env.PORT ?? 3001;

app.use(cors());
app.use(express.json());
app.use(metricsMiddleware);   // time every request -> Prometheus histogram
app.use(requestLogger);       // one structured JSON log line per request -> stdout -> Fluent Bit
app.use('/', metricsRouter);
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

const server = app.listen(PORT, () => logger.info('backend started', { port: PORT }));

// Kubernetes stops a pod with SIGTERM. Node running as PID 1 has no default handler for it,
// so without this the pod would hang until the 30s grace period ends and it gets SIGKILL.
process.on('SIGTERM', () => {
    logger.info('SIGTERM received, closing server');
    server.close(() => process.exit(0));
});