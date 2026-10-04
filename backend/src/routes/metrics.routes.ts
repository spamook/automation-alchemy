import { Router } from 'express';
import { getMetrics } from '../controllers/metrics.controller';
import { prometheusHandler } from '../prometheus';

const router = Router();
router.get('/metrics', getMetrics);           // JSON — consumed by the adaptive load balancer (unchanged)
router.get('/prometheus', prometheusHandler); // Prometheus text format — scraped by Prometheus
export default router;