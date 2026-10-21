# ADR-0004: Deliver telemetry over OTLP through a Collector bridge

- **Status:** Accepted
- **Date:** 2026-10-20
- **Feature:** 001-mock-pms (research R16)

## Context

Constitution Principle VI (v1.1.0) requires every service to send its logs and metrics over OTLP to a single OTLP-compatible backend. The backend must be swappable through configuration alone, and exporting must never block or fail work. The local backend is OpenObserve.

In Ruby, only OpenTelemetry *tracing* is stable. The metrics and logs SDKs are still 0.x gems: their APIs can change between minor releases, and the metrics SDK doesn't yet implement the whole spec.

## Decision

The services emit two stable formats and do no OTLP work themselves:

- JSON logs on stdout, using OpenTelemetry semantic-convention field names such as `service.name` and `code.function.name`.
- Prometheus text on `/metrics`, including a `target_info` line.

An OpenTelemetry Collector (the `contrib` distribution, image tag pinned) converts both to OTLP and sends them to OpenObserve:

- **Logs:** the `filelog` receiver tails Docker's json-file logs. It keeps only lines whose own `service.name` begins with `mock_pms`, and moves the resource fields into OTLP resource attributes.
- **Metrics:** the `prometheus` receiver scrapes a single `/metrics` target, because every instance returns cluster-wide totals from Redis. A `transform` processor turns the `target_info` labels into `service.version` and `deployment.environment`.
- **Processing and export:** the `memory_limiter`, `attributes/redact` (a second layer of redaction) and `batch` processors run before the `otlphttp` exporter, which uses basic auth.
- **Self-monitoring:** the Collector scrapes its own metrics on `:8888` so that its drop counters reach the backend too.

## Alternatives considered

- **Native OpenTelemetry metrics and logs SDKs in the app.** Rejected for now. The 0.x gems risk API churn, and each instance would export its own series, which makes the Redis aggregation pointless.
- **Docker's `fluentd` logging driver with the Collector's `fluentforward` receiver.** Rejected. The Docker daemon would have to reach the Collector on a published port, and containers fail to start while the Collector is down unless they run in async mode.
- **Shipping straight to OpenObserve's own ingestion API.** Rejected, because it breaks Principle VI's vendor-neutral rule.

## Consequences

- The services have no OpenTelemetry dependencies. Changing the backend means editing one exporter block.
- The Collector's sending queue lives in memory. A Collector restart loses whatever is queued at that moment, which is at most `queue_size` batches during a backend outage. Service logs remain in Docker's files, and metric totals remain in Redis.
- The Collector's drops are counted (`otelcol_exporter_send_failed_*`) and exported once the backend is reachable again.
- The Collector depends on Docker's json-file log driver and on read access to `/var/lib/docker/containers`. T101 confirms this works under Docker Desktop.
- **Revisit** when the Ruby OpenTelemetry metrics and logs SDKs reach 1.0. Moving to them then only changes the Collector's receivers.
