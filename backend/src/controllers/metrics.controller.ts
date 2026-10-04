import { Request, Response } from 'express';
import { collectMetrics } from '../services/metrics.service';
import { metricsServedTotal } from '../prometheus';

export function getMetrics(_req: Request, res: Response): void {
    metricsServedTotal.inc();
    res.json(collectMetrics());
}