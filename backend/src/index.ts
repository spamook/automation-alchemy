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
app.use(requestLogger);       // one structured JSON log line per request -> stdout -> Filebeat
app.use('/', metricsRouter);
app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.listen(PORT, () => logger.info('backend started', { port: PORT }));