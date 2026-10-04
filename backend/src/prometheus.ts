import { Request, Response, NextFunction } from 'express';
import client from 'prom-client';

// A dedicated registry holds all metrics we expose on /prometheus.
export const register = new client.Registry();

// Label attached to every metric — lets us tell app-server from the web sidecars in Grafana.
register.setDefaultLabels({ app: 'infra-backend' });

// Node process metrics out of the box: CPU, heap, event-loop lag, GC, open handles, etc.
client.collectDefaultMetrics({ register });

// --- Custom metric #1: request duration histogram ---------------------------
// One histogram gives us BOTH the "Response times" and "Error rates" panels:
//  - buckets  -> latency distribution / percentiles
//  - status_code label -> count of 4xx/5xx vs 2xx
const httpDuration = new client.Histogram({
    name: 'http_request_duration_seconds',
    help: 'Duration of HTTP requests in seconds',
    labelNames: ['method', 'route', 'status_code'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
    registers: [register],
});

// --- Custom metric #2: the required "1 custom application metric" -----------
// Counts how many times the app served system metrics (its core business action).
// Easy to demo: curl /metrics a few times and watch it climb in Grafana.
export const metricsServedTotal = new client.Counter({
    name: 'infra_metrics_served_total',
    help: 'Total number of times the backend served system metrics',
    registers: [register],
});

// Express middleware: times every request and records it in the histogram.
export function metricsMiddleware(req: Request, res: Response, next: NextFunction): void {
    const stop = httpDuration.startTimer();
    res.on('finish', () => {
        stop({
            method: req.method,
            // Use the route pattern, not the raw URL: random 404 paths from scanners
            // would otherwise create a new time series each (label cardinality explosion).
            route: req.route?.path ?? 'unmatched',
            status_code: res.statusCode,
        });
    });
    next();
}

// Handler for GET /prometheus — outputs all metrics in Prometheus text format.
export async function prometheusHandler(_req: Request, res: Response): Promise<void> {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
}
