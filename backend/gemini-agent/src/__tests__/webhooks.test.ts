import { afterEach, describe, expect, it } from "bun:test";
import express from "express";
import type { Server } from "node:http";
import { createWebhookRouter } from "../api/webhooks.js";
import { InventoryLedger } from "../inventory/inventoryLedger.js";

const config = { restockThresholdDays: 3, restockBelowGrams: 50 };
const servers: Server[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
});

describe("webhook logging", () => {
  it("logs task keys without logging the request body", async () => {
    const app = express();
    app.use(express.json());
    app.use("/v1/webhooks", createWebhookRouter(new InventoryLedger({ idempotencyTtlSeconds: 60 }), config));
    const server = await new Promise<Server>((resolve) => {
      const value = app.listen(0, "127.0.0.1", () => resolve(value));
      servers.push(value);
    });
    const port = (server.address() as { port: number }).port;
    const originalLog = console.log;
    const lines: string[] = [];
    console.log = (...args: unknown[]) => lines.push(args.join(" "));
    try {
      const response = await fetch(`http://127.0.0.1:${port}/v1/webhooks/tasks`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ taskType: "enrich_inventory", userQuestion: "private user text" })
      });
      expect(response.status).toBe(200);
      expect(lines.join("\n")).toContain("userQuestion");
      expect(lines.join("\n")).not.toContain("private user text");
    } finally {
      console.log = originalLog;
    }
  });
});
