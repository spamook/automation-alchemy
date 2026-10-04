import { Request, Response, NextFunction } from 'express';
import { createLogger, format, transports } from 'winston';

// Structured JSON logger writing to stdout.
// Why JSON + stdout: Docker captures stdout, Filebeat ships those container logs,
// and Logstash can parse the JSON straight into Elasticsearch fields (no fragile grok).
export const logger = createLogger({
    level: process.env.LOG_LEVEL ?? 'info',
    format: format.combine(
        format.timestamp(),
        format.json(),
    ),
    defaultMeta: { service: 'infra-backend' },
    transports: [new transports.Console()],
});

// Log level derived from the response: 5xx -> error, 4xx -> warn, rest -> info.
// Prometheus scrapes (every 15s) are logged at debug so they don't flood Elasticsearch.
function levelFor(path: string, status: number): string {
    if (path === '/prometheus') return 'debug';
    if (status >= 500) return 'error';
    if (status >= 400) return 'warn';
    return 'info';
}

// Emits one structured log line per HTTP request: method, path, status, duration.
// This becomes the "access log" in the Kibana Application Logs dashboard.
export function requestLogger(req: Request, res: Response, next: NextFunction): void {
    const start = process.hrtime.bigint();
    res.on('finish', () => {
        const durationMs = Number(process.hrtime.bigint() - start) / 1e6;
        logger.log(levelFor(req.path, res.statusCode), 'http_request', {
            method: req.method,
            path: req.path,
            status: res.statusCode,
            durationMs: Math.round(durationMs),
        });
    });
    next();
}
