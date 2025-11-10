# Visualizing your Telemetry

This folder will assist you in deploying a Grafana observability stack to help visualize Telemetry data exported from your Telemetry Controller deployment. After going through the installation process you will have the following:
- Grafana observability stack running in Docker. Includes
  - Grafana (User Interface) with sample dashboards for z/OS metrics and logs.
  - Tempo (Traces)
  - Prometheus (Metrics)
  - Loki (Logs)

## Prerequisites

Before continuing please ensure you have done the following:
- Have Docker installed
- You should be familiar with the Telemetry Controller configuration and deployment process
- Collect your Telemetry Controller's FQDN (telemetry-controller-fqdn)
- Collect the FQDN of this machine (visualization-fqdn)

## Deploying the Grafana stack

### Configure the Telemetry Controller

To ensure your Telemetry is exported to the Grafana stack you need to configure the custom OpenTelemetry Collector exporters to send your data to the correct endpoint.

#### Traces

For traces, add the following snippet to your collector configuration:

In your collector's exporter section:
```YAML
  otlp/tempo:
    endpoint: <visualization-fqdn>:4317
    tls:
      insecure: true
```

In your trace pipeline, you should add `otlp/tempo` to the exporter list.

#### Metrics

For metrics, add the following snippet to your collector configuration:

In your collector's exporter section:
```YAML
  prometheus:
    endpoint: 0.0.0.0:8889
    add_metric_suffixes: true
    const_labels:
      exporter: opentelemetry
    resource_to_telemetry_conversion:
      enabled: true
    enable_open_metrics: true
```

In your exporter pipeline, add `prometheus` to the metrics list.

#### Logs

For logs, add the following snippet to your collector configuration:

In your collector's exporter section:
```YAML
  otlphttp:
    endpoint: http://<visualization-fqdn>:3100/otlp
```

In your exporter pipeline, add `otlphttp` to the logs list.

### Configure the Grafana stack

If using metrics, update the `otel-collector` scrape job targets in the [Prometheus config](./config/tools/prometheus.yml) to scrape from your Telemetry Controller.

For example, if your Telemetry Controller FQDN is: `tc-fqdn.company.endpoint`, you would update the YAML to be:
```YAML
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
- job_name: 'prometheus'
  static_configs:
  - targets: [ "localhost:9090" ]
- job_name: "otel-collector"
  scrape_interval: 10s
  static_configs:
  - targets: [ "tc-fqdn.company.endpoint:8889" ]
  - targets: [ "tc-fqdn.company.endpoint:8888" ]
```

### Deploy

Once you have finished the configuration steps:
1. Deploy the Grafana stack by running the following in the terminal:
    ```bash
    docker compose up -d
    ```
2. Follow the official Telemetry Controller documentation to deploy the Telemetry Controller

You should be able to access your Grafana UI at the following URL: `http://<visualization-fqdn>:3000`.